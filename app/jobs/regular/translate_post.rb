# frozen_string_literal: true

module Jobs
  class TranslatePost < ::Jobs::Base
    sidekiq_options retry: 25, backtrace: true

    def execute(args)
      return unless SiteSetting.multilingual_post_enabled

      post = Post.find_by(id: args[:post_id])
      return if post.blank?
      return if post.user.blank?

      raw = post.raw.to_s
      return if raw.strip.empty?

      llm = MultilingualPost::LlmClient.from_env
      source = post.user.locale.to_s
      targets = MultilingualPost::TIER1_LOCALES - [source]

      result = llm.translate(text: raw, source_locale: source, targets: targets)

      result.translations.each do |locale, translated|
        next if translated.blank?

        record =
          PostTranslation.upsert_completed(
            post_id: post.id,
            locale: locale,
            raw: translated,
            cooked: PrettyText.cook(translated),
            source_locale: source,
          )

        MessageBus.publish(
          "/post-translation/#{post.id}",
          {
            post_id: post.id,
            locale: record.locale,
            source_locale: record.source_locale,
            cooked: record.cooked,
          },
        )
      end
    end
  end
end
