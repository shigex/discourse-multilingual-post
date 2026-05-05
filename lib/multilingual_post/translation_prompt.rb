# frozen_string_literal: true

module MultilingualPost
  # Renders the TranslateGemma chat template for a single (source, target, text) tuple.
  #
  # TranslateGemma 12B has a specialized chat template that does NOT pass through
  # vllm-mlx's OpenAI-compatible /chat/completions endpoint (the per-message
  # source_lang_code / target_lang_code fields are stripped before reaching the
  # tokenizer). We render the template ourselves and submit to /v1/completions
  # as a raw prompt. One call produces ONE target-language translation.
  module TranslationPrompt
    # Discourse uses BCP-47 with region (zh-CN, zh-TW). TranslateGemma's chat
    # template ships with `zh-TW` and `zh-Hans` / `zh-Hant` but NOT `zh-CN`.
    # All Chinese variants render as "Chinese" in the prompt regardless;
    # the actual script (Simplified vs Traditional) is steered by the code.
    LOCALE_TO_TRANSLATEGEMMA = {
      "zh-CN" => "zh-Hans",
      # zh-TW passes through (template ships it)
    }.freeze

    # ISO 639-1 → English language name. Mirrors the (much larger) `languages`
    # dict in chat_template.jinja for codes we actually use.
    LANGUAGE_NAMES = {
      "ja" => "Japanese",
      "en" => "English",
      "ko" => "Korean",
      "de" => "German",
      "es" => "Spanish",
      "fr" => "French",
      "pt" => "Portuguese",
      "it" => "Italian",
      "ru" => "Russian",
      "bn" => "Bengali",
      "vi" => "Vietnamese",
      "id" => "Indonesian",
      "pl" => "Polish",
      "zh-Hans" => "Chinese",
      "zh-Hant" => "Chinese",
      "zh-TW" => "Chinese",
      "zh-CN" => "Chinese", # mapped before render, but keep for safety
      "zh" => "Chinese",
    }.freeze

    module_function

    # Map a Discourse locale to the form TranslateGemma's template accepts.
    def normalize_locale(locale)
      LOCALE_TO_TRANSLATEGEMMA.fetch(locale.to_s, locale.to_s)
    end

    def language_name(locale)
      LANGUAGE_NAMES.fetch(normalize_locale(locale), locale.to_s)
    end

    # Render the exact prompt that TranslateGemma's chat_template.jinja
    # produces for {role:user, content:[{type:text, source_lang_code, target_lang_code, text}]}
    # with add_generation_prompt=True.
    #
    # Reference output (verified against the actual tokenizer):
    #   <bos><start_of_turn>user
    #   You are a professional Japanese (ja) to English (en) translator. ...
    #   Produce only the English translation, ...:
    #
    #
    #   {text}<end_of_turn>
    #   <start_of_turn>model
    #
    def render(source_locale:, target_locale:, text:)
      src = normalize_locale(source_locale)
      tgt = normalize_locale(target_locale)
      src_name = language_name(src)
      tgt_name = language_name(tgt)

      <<~PROMPT
        <bos><start_of_turn>user
        You are a professional #{src_name} (#{src}) to #{tgt_name} (#{tgt}) translator. Your goal is to accurately convey the meaning and nuances of the original #{src_name} text while adhering to #{tgt_name} grammar, vocabulary, and cultural sensitivities.
        Produce only the #{tgt_name} translation, without any additional explanations or commentary. Please translate the following #{src_name} text into #{tgt_name}:


        #{text}<end_of_turn>
        <start_of_turn>model

      PROMPT
    end
  end
end
