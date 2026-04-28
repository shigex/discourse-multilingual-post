# frozen_string_literal: true

module MultilingualPost
  module TranslationPrompt
    SYSTEM = <<~PROMPT
      You are a translation engine for a 250-resident multilingual share-house forum.

      Detect the source language of the message. Then translate it to each of the
      target locales requested by the user message.

      Rules:
      - Preserve emoji, @mentions (@username), and URLs as-is.
      - Keep colloquial / casual tone — do not formalize chat-style messages.
      - Do NOT translate proper nouns (Bayview, building/floor names, brand names).
      - For Chinese: zh-CN = Simplified, zh-TW = Traditional. Do not mix.
      - Output STRICT JSON only. No markdown, no commentary.
      - Schema: {"source": "<bcp-47>", "translations": {"<bcp-47>": "<text>", ...}}

      If the message is empty or untranslatable, return:
      {"source": "<your best guess>", "translations": {}}
    PROMPT

    LOCALE_LABELS = {
      "ja" => "Japanese (ja)",
      "en" => "English (en)",
      "ko" => "Korean (ko)",
      "de" => "German (de)",
      "es" => "Spanish (es)",
      "zh-CN" => "Simplified Chinese (zh-CN)",
      "zh-TW" => "Traditional Chinese (zh-TW)",
      "fr" => "French (fr)",
      "pt" => "Portuguese (pt)",
      "it" => "Italian (it)",
      "ru" => "Russian (ru)",
      "bn" => "Bengali (bn)",
      "vi" => "Vietnamese (vi)",
      "id" => "Indonesian (id)",
      "pl" => "Polish (pl)",
    }.freeze

    def self.user_message(text:, targets:)
      labelled = targets.map { |loc| LOCALE_LABELS.fetch(loc, loc) }.join(", ")
      <<~MSG
        Target locales: #{labelled}

        Message:
        """
        #{text}
        """
      MSG
    end
  end
end
