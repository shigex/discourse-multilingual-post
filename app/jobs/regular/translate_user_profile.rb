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

      TRANSLATABLE.each do |field|
        text = read_field(user, profile, field)
        next if text.blank?

        targets = MultilingualPost::TIER1_LOCALES - [user.locale.to_s]

        begin
          result = llm.translate(text: text, targets: targets)
        rescue MultilingualPost::LlmClient::AuthError, MultilingualPost::LlmClient::InvalidResponseError
          # Permanent failures: skip rather than blocking retries forever.
          next
        end

        source = result.source_locale.presence || user.locale.to_s

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
