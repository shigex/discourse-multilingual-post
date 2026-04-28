# frozen_string_literal: true

# name: discourse-multilingual-post
# about: Per-post and per-profile translation cached by user-preferred locale, served from a local LLM.
# version: 0.1.0
# authors: Shige Kondou
# url: https://github.com/shigeyukikondou/discourse-multilingual-post

enabled_site_setting :multilingual_post_enabled

register_asset "stylesheets/multilingual-post.scss"

after_initialize do
  module ::MultilingualPost
    PLUGIN_NAME = "discourse-multilingual-post"

    # Tier 1: pre-cache on every post.
    TIER1_LOCALES = %w[ja en ko de es zh-CN zh-TW fr].freeze

    # Tier 2: lazy-translate on first viewer access.
    TIER2_LOCALES = %w[pt it ru bn vi id pl].freeze

    SUPPORTED_LOCALES = (TIER1_LOCALES + TIER2_LOCALES).freeze

    # Languages where a flag is OK to display alongside native-script label.
    # Languages spoken across many countries (en, es, zh-*, fr, pt, it, ru, bn)
    # intentionally use native-script label only — see plan §"国旗を使わない理由".
    FLAG_OK_LOCALES = %w[ja ko de pl vi id].freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace MultilingualPost
    end
  end

  require_relative "lib/multilingual_post/llm_client"
  require_relative "lib/multilingual_post/translation_prompt"
  require_relative "app/models/post_translation"
  require_relative "app/models/user_profile_translation"
  require_relative "app/jobs/regular/translate_post"
  require_relative "app/jobs/regular/translate_user_profile"
  require_relative "app/services/avatar_importer"

  # ────────────────────────────────────────────
  # Hooks: enqueue translation jobs on post / user updates
  # ────────────────────────────────────────────
  on(:post_created) do |post, _opts, _user|
    next if post.blank? || post.user.blank?
    next if post.user.bot?
    Jobs.enqueue(:translate_post, post_id: post.id)
  end

  on(:post_edited) do |post, topic_changed, _post_revisor|
    next if post.blank?
    Jobs.enqueue(:translate_post, post_id: post.id)
  end

  on(:user_updated) do |user|
    next if user.blank?
    Jobs.enqueue(:translate_user_profile, user_id: user.id)
  end

  on(:after_create_account) do |user, opts|
    # OAuth provisioning: import avatar from LINE/Google CDN to R2.
    next if user.blank?
    auth = opts[:authentication]
    next if auth.blank?

    Jobs.enqueue(
      :import_oauth_avatar,
      user_id: user.id,
      provider: auth[:provider],
      avatar_url: auth[:avatar_url]
    ) if auth[:avatar_url].present?
  end

  # ────────────────────────────────────────────
  # Serializer additions: expose translation state to client
  # ────────────────────────────────────────────
  add_to_serializer(:post, :translation) do
    locale = scope&.user&.locale
    next nil if locale.blank?
    next nil if object.user&.locale == locale # source matches viewer

    translation = PostTranslation.find_by(post_id: object.id, locale: locale)
    next nil if translation.blank?

    {
      locale: translation.locale,
      source_locale: translation.source_locale,
      raw: translation.raw,
      cooked: translation.cooked,
      status: translation.status,
    }
  end

  add_to_serializer(:post, :source_locale) do
    PostTranslation.where(post_id: object.id).pick(:source_locale) ||
      object.user&.locale
  end

  # Expose mp_onboarded so the JS knows whether to launch the onboarding modal.
  add_to_serializer(:current_user, :custom_fields) do
    object.custom_fields.slice("mp_onboarded", "spoken_languages", "open_to", "stay_period", "hobbies", "floor_room")
  end

  # Bio translation for user profile pages — viewer-locale-aware.
  add_to_serializer(:user_card, :bio_translation) do
    locale = scope&.user&.locale
    next nil if locale.blank?
    next nil if object.user_profile&.bio_raw.blank?
    record = UserProfileTranslation.find_by(
      user_id: object.id, field_name: "bio_raw", locale: locale,
    )
    record && {
      locale: record.locale,
      raw: record.raw,
      source_locale: record.source_locale,
      status: record.status,
    }
  end
end
