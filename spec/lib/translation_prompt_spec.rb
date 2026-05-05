# frozen_string_literal: true

require "rails_helper"

describe MultilingualPost::TranslationPrompt do
  describe ".normalize_locale" do
    it "maps zh-CN → zh-Hans (TranslateGemma's chat template doesn't ship zh-CN)" do
      expect(described_class.normalize_locale("zh-CN")).to eq("zh-Hans")
    end

    it "leaves zh-TW unchanged (template ships it)" do
      expect(described_class.normalize_locale("zh-TW")).to eq("zh-TW")
    end

    it "leaves bare ISO 639-1 codes unchanged" do
      %w[ja en ko de es fr pt it ru bn vi id pl].each do |loc|
        expect(described_class.normalize_locale(loc)).to eq(loc)
      end
    end
  end

  describe ".language_name" do
    it "returns English names for Tier 1+2 codes" do
      expect(described_class.language_name("ja")).to eq("Japanese")
      expect(described_class.language_name("zh-CN")).to eq("Chinese")
      expect(described_class.language_name("zh-TW")).to eq("Chinese")
      expect(described_class.language_name("zh-Hans")).to eq("Chinese")
      expect(described_class.language_name("ko")).to eq("Korean")
      expect(described_class.language_name("de")).to eq("German")
    end

    it "falls back to the locale code when unknown" do
      expect(described_class.language_name("xx")).to eq("xx")
    end
  end

  describe ".render" do
    let(:text) { "今日は天気がいい。" }

    it "produces a prompt with TranslateGemma's required surface tokens" do
      out = described_class.render(source_locale: "ja", target_locale: "en", text: text)

      expect(out).to include("<bos><start_of_turn>user")
      expect(out).to include("<end_of_turn>")
      expect(out).to include("<start_of_turn>model")
      expect(out).to include(text)
    end

    it "includes both source and target language names AND ISO codes in the instruction" do
      out = described_class.render(source_locale: "ja", target_locale: "ko", text: text)
      expect(out).to include("Japanese (ja)")
      expect(out).to include("Korean (ko)")
    end

    it "uses the mapped locale code in the instruction text (zh-CN → zh-Hans)" do
      out = described_class.render(source_locale: "ja", target_locale: "zh-CN", text: text)
      expect(out).to include("(zh-Hans)")
      expect(out).not_to include("(zh-CN)")
    end

    it "preserves zh-TW in the instruction text" do
      out = described_class.render(source_locale: "ja", target_locale: "zh-TW", text: text)
      expect(out).to include("(zh-TW)")
    end
  end
end
