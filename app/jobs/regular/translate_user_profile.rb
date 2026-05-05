# frozen_string_literal: true

module Jobs
  class TranslateUserProfile < ::Jobs::Base
    sidekiq_options retry: 25, backtrace: true

    TRANSLATABLE = UserProfileTranslation::TRANSLATABLE_FIELDS

    def execute(args)
      return unless SiteSetting.multilingual_post_enabled

      user = User.find_by(id: args[:user_id])
      return if user.blank?

      profile = user.user_profile
      return if profile.blank?

      llm = MultilingualPost::LlmClient.from_env

      # Fall back to the site's default locale when the user has not picked one
      # yet (e.g. legacy accounts created before the locale-required onboarding).
      # Without this, source_locale would be "" and TranslateGemma would reject
      # the request — wasting a round trip per field.
      source = user.locale.presence || SiteSetting.default_locale.to_s

      TRANSLATABLE.each do |field|
        text = read_field(user, profile, field)
        next if text.blank?

        targets = MultilingualPost::TIER1_LOCALES - [source]
        next if targets.empty?

        # AuthError → re-raise so Sidekiq stops retrying *and* surfaces the
        # service-token problem; matches Jobs::TranslatePost.
        # TransientError → re-raise so Sidekiq retries the whole job.
        # InvalidResponseError → skip this field (junk LLM output is per-field;
        # other fields in the same profile may still succeed).
        begin
          result = llm.translate(text: text, source_locale: source, targets: targets)
        rescue MultilingualPost::LlmClient::InvalidResponseError
          next
        end

        result.translations.each do |locale, translated|
          next if translated.blank?

          UserProfileTranslation.upsert_completed(
            user_id: user.id,
            field_name: field,
            locale: locale,
            raw: translated,
            source_locale: source,
          )
        end

        # TODO: persist `result.failed_targets` as status='failed' rows so the
        # UI can show "translation unavailable" instead of silently falling back
        # to the source. Mirrors a similar TODO in Jobs::TranslatePost.

        MessageBus.publish(
          "/user-profile-translation/#{user.id}",
          { user_id: user.id, field: field },
        )
      end
    end

    private

    def read_field(user, profile, field)
      case field
      when "bio_raw" then profile.bio_raw
      when "hobbies" then user.custom_fields["hobbies"]
      when "stay_period" then user.custom_fields["stay_period"]
      end
    end
  end
end
