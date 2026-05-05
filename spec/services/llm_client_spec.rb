# frozen_string_literal: true

require "rails_helper"

describe MultilingualPost::LlmClient do
  let(:base_url) { "https://llm.kondou.com/v1" }
  let(:client) do
    described_class.new(
      base_url: base_url,
      model: "translategemma-12b-q4",
      access_client_id: "id-xxx",
      access_client_secret: "sec-xxx",
    )
  end

  before do
    stub_const("ENV", ENV.to_h.merge(
      "TRANSLATION_LLM_BASE_URL" => base_url,
      "TRANSLATION_LLM_MODEL" => "translategemma-12b-q4",
      "TRANSLATION_LLM_CF_ACCESS_CLIENT_ID" => "id-xxx",
      "TRANSLATION_LLM_CF_ACCESS_CLIENT_SECRET" => "sec-xxx",
    ))
  end

  describe ".from_env" do
    it "constructs from env vars" do
      c = described_class.from_env
      expect(c.base_url).to eq(base_url)
      expect(c.model).to eq("translategemma-12b-q4")
    end
  end

  describe "#translate" do
    let(:source_locale) { "ja" }
    let(:source_text) { "こんにちは" }

    def stub_completion(target_text:, status: 200, body_override: nil)
      stub_request(:post, "#{base_url}/completions")
        .with(headers: {
          "Content-Type" => "application/json",
          "CF-Access-Client-Id" => "id-xxx",
          "CF-Access-Client-Secret" => "sec-xxx",
        })
        .to_return(
          status: status,
          body: body_override || { choices: [{ text: target_text, finish_reason: "stop" }] }.to_json,
          headers: { "Content-Type" => "application/json" },
        )
    end

    it "issues one POST to /v1/completions per target language and aggregates results" do
      stub_completion(target_text: "Hello") # webmock returns same body for all matching requests

      result = client.translate(text: source_text, source_locale: source_locale, targets: %w[en ko de])

      # 3 targets × 1 request each
      expect(WebMock).to have_requested(:post, "#{base_url}/completions").times(3)
      expect(result.source_locale).to eq("ja")
      expect(result.translations.keys).to match_array(%w[en ko de])
      expect(result.failed_targets).to be_empty
    end

    it "renders the TranslateGemma chat template (with source/target language names) into the prompt" do
      captured_bodies = []
      stub_request(:post, "#{base_url}/completions").with do |req|
        captured_bodies << JSON.parse(req.body)
        true
      end.to_return(status: 200, body: { choices: [{ text: "ok" }] }.to_json)

      client.translate(text: source_text, source_locale: "ja", targets: %w[en])

      prompt = captured_bodies.first["prompt"]
      expect(prompt).to include("Japanese (ja)")
      expect(prompt).to include("English (en)")
      expect(prompt).to include("<start_of_turn>user")
      expect(prompt).to include("<start_of_turn>model")
      expect(prompt).to include(source_text)
    end

    it "maps zh-CN to zh-Hans in the rendered prompt (TranslateGemma doesn't ship zh-CN)" do
      captured = nil
      stub_request(:post, "#{base_url}/completions").with do |req|
        captured = JSON.parse(req.body)
        true
      end.to_return(status: 200, body: { choices: [{ text: "你好" }] }.to_json)

      client.translate(text: source_text, source_locale: "ja", targets: %w[zh-CN])

      expect(captured["prompt"]).to include("(zh-Hans)") # mapped form
      expect(captured["prompt"]).not_to include("(zh-CN)")
    end

    it "leaves zh-TW as-is (already in TranslateGemma's language map)" do
      captured = nil
      stub_request(:post, "#{base_url}/completions").with do |req|
        captured = JSON.parse(req.body)
        true
      end.to_return(status: 200, body: { choices: [{ text: "你好" }] }.to_json)

      client.translate(text: source_text, source_locale: "ja", targets: %w[zh-TW])

      expect(captured["prompt"]).to include("(zh-TW)")
    end

    it "raises TransientError on 5xx so Sidekiq retries the whole job" do
      stub_request(:post, "#{base_url}/completions").to_return(status: 503, body: "boom")

      expect {
        client.translate(text: source_text, source_locale: "ja", targets: %w[en ko])
      }.to raise_error(described_class::TransientError)
    end

    it "raises AuthError on 401 (Service Token rejected)" do
      stub_request(:post, "#{base_url}/completions").to_return(status: 401, body: "{}")

      expect {
        client.translate(text: source_text, source_locale: "ja", targets: %w[en])
      }.to raise_error(described_class::AuthError)
    end

    it "raises AuthError on 403 (Cloudflare Access blocked)" do
      stub_request(:post, "#{base_url}/completions").to_return(status: 403, body: "")

      expect {
        client.translate(text: source_text, source_locale: "ja", targets: %w[en])
      }.to raise_error(described_class::AuthError)
    end

    it "puts target into failed_targets when LLM returns an empty completion (permanent skip)" do
      stub_request(:post, "#{base_url}/completions")
        .to_return(status: 200, body: { choices: [{ text: "" }] }.to_json)
        .then.to_return(status: 200, body: { choices: [{ text: "Hello" }] }.to_json)

      result = client.translate(text: source_text, source_locale: "ja", targets: %w[en ko])

      # one target failed (empty), the other succeeded
      expect(result.failed_targets.length + result.translations.length).to eq(2)
    end

    it "returns an empty Result without HTTP calls when text is blank" do
      result = client.translate(text: "  ", source_locale: "ja", targets: %w[en ko])
      expect(result.translations).to be_empty
      expect(WebMock).not_to have_requested(:post, "#{base_url}/completions")
    end

    it "returns an empty Result without HTTP calls when targets is empty" do
      result = client.translate(text: "hello", source_locale: "ja", targets: [])
      expect(result.translations).to be_empty
      expect(WebMock).not_to have_requested(:post, "#{base_url}/completions")
    end
  end
end
