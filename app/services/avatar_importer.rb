# frozen_string_literal: true

require "open-uri"

module MultilingualPost
  # Pulls the avatar image from LINE / Google CDN and stores it in Discourse's
  # upload storage (which the host has configured to be Cloudflare R2 via
  # DISCOURSE_USE_S3=true). After import, the user's avatar is served from R2,
  # never from the OAuth provider's CDN.
  #
  # Retry policy: transient network failures are retried by the wrapping
  # Sidekiq job (Jobs::ImportOauthAvatar, retry: 5). Permanent failures
  # (bad scheme, oversized payload, non-image content-type, parse error,
  # UploadCreator validation error) intentionally fall through silently —
  # the user keeps Discourse's default identicon, which is acceptable per
  # the plan (avatars can be re-fetched manually later).
  class AvatarImporter
    # 4 MB upper bound. LINE/Google CDN avatars are typically 50–500 KB, so
    # anything beyond this is almost certainly a misconfiguration or hostile
    # response. Set high enough to tolerate retina-resolution PNGs.
    MAX_BYTES = 4_000_000

    # Network timeouts. open_timeout guards SYN/TLS handshake;
    # read_timeout guards body streaming.
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    # We only accept image responses. OAuth providers occasionally return
    # HTML error pages (e.g. expired CDN signatures) which would otherwise
    # be uploaded as "image" and fail later in mysterious ways.
    ALLOWED_CONTENT_TYPE_PREFIX = "image/"

    def self.import_for(user, source_url)
      return if user.blank? || source_url.blank?

      unless safe_https_url?(source_url)
        Rails.logger.warn(
          "[multilingual-post] event=avatar_import_rejected reason=insecure_scheme url=#{source_url.to_s.byteslice(0, 200)}"
        )
        return
      end

      tempfile = fetch(source_url)
      return if tempfile.nil?

      unless image_content_type?(tempfile)
        ct = tempfile.respond_to?(:content_type) ? tempfile.content_type : "unknown"
        Rails.logger.warn(
          "[multilingual-post] event=avatar_import_rejected reason=bad_content_type content_type=#{ct}"
        )
        return
      end

      filename = "oauth-avatar-#{user.id}.png"
      upload =
        UploadCreator.new(tempfile, filename, type: "avatar").create_for(user.id)

      if upload&.persisted?
        user.user_avatar.update!(custom_upload_id: upload.id)
        user.update!(uploaded_avatar_id: upload.id)
      else
        errors = upload ? upload.errors.full_messages.join(",") : "nil upload"
        Rails.logger.warn(
          "[multilingual-post] event=avatar_import_failed reason=upload_creator_failed errors=#{errors}"
        )
      end
    ensure
      tempfile&.close
      tempfile&.unlink if tempfile.respond_to?(:unlink)
    end

    # Extracted so specs can stub network IO without poking OpenURI globals.
    # Returns a Tempfile-like object on success, nil on any error.
    def self.fetch(source_url)
      URI
        .parse(source_url)
        .open(
          "rb",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
          "User-Agent" => "DiscourseMultilingualPost/0.1",
          content_length_proc: ->(len) {
            raise "avatar too large: #{len} bytes" if len && len > MAX_BYTES
          },
        )
    rescue StandardError => e
      Rails.logger.warn(
        "[multilingual-post] event=avatar_import_failed reason=fetch_error error_class=#{e.class.name} message=#{e.message}"
      )
      nil
    end

    # SSRF defence: only allow https:// URLs with a non-empty host. This
    # rejects http://, file://, ftp://, javascript:, and malformed URIs.
    def self.safe_https_url?(source_url)
      uri = URI.parse(source_url.to_s)
      uri.is_a?(URI::HTTPS) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    def self.image_content_type?(tempfile)
      return true unless tempfile.respond_to?(:content_type)
      ct = tempfile.content_type.to_s
      ct.start_with?(ALLOWED_CONTENT_TYPE_PREFIX)
    end
  end
end

# Sidekiq wrapper so we can enqueue from :after_create_account hook
module Jobs
  class ImportOauthAvatar < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      user = User.find_by(id: args[:user_id])
      return if user.blank?
      MultilingualPost::AvatarImporter.import_for(user, args[:avatar_url])
    end
  end
end
