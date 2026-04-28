# frozen_string_literal: true

require "open-uri"

module MultilingualPost
  # Pulls the avatar image from LINE / Google CDN and stores it in Discourse's
  # upload storage (which the host has configured to be Cloudflare R2 via
  # DISCOURSE_USE_S3=true). After import, the user's avatar is served from R2,
  # never from the OAuth provider's CDN.
  class AvatarImporter
    MAX_BYTES = 4_000_000 # 4 MB upper bound — guards against accidental huge files

    def self.import_for(user, source_url)
      return if user.blank? || source_url.blank?

      tempfile =
        begin
          URI
            .parse(source_url)
            .open(
              "rb",
              read_timeout: 15,
              "User-Agent" => "DiscourseMultilingualPost/0.1",
              content_length_proc: ->(len) {
                raise "avatar too large: #{len} bytes" if len && len > MAX_BYTES
              },
            )
        rescue StandardError => e
          Rails.logger.warn("[multilingual-post] avatar fetch failed: #{e.message}")
          return
        end

      filename = "oauth-avatar-#{user.id}.png"
      upload =
        UploadCreator.new(tempfile, filename, type: "avatar").create_for(user.id)

      if upload.persisted?
        user.user_avatar.update!(custom_upload_id: upload.id)
        user.update!(uploaded_avatar_id: upload.id)
      else
        Rails.logger.warn(
          "[multilingual-post] UploadCreator failed: #{upload.errors.full_messages.join(",")}"
        )
      end
    ensure
      tempfile&.close
      tempfile&.unlink if tempfile.respond_to?(:unlink)
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
