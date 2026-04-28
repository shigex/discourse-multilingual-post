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
    let(:targets) { %w[en ko de] }
    let(:llm_response_json) do
      {
        choices: [
          {
            message: {
              role: "assistant",
              content: '{"source":"ja","translations":{"en":"Hello","ko":"안녕","de":"Hallo"}}',
            },
          },
        ],
      }.to_json
    end

    it "POSTs to /chat/completions with Cloudflare Access service token headers" do
      stub = stub_request(:post, "#{base_url}/chat/completions").with(
        headers: {
          "Content-Type" => "application/json",
          "CF-Access-Client-Id" => "id-xxx",
          "CF-Access-Client-Secret" => "sec-xxx",
        },
      ).to_return(status: 200, body: llm_response_json, headers: { "Content-Type" => "application/json" })

      result = client.translate(text: "こんにちは", targets: targets)

      expect(stub).to have_been_requested
      expect(result.source_locale).to eq("ja")
      expect(result.translations).to eq("en" => "Hello", "ko" => "안녕", "de" => "Hallo")
    end

    it "raises a recognizable error on 5xx (so Sidekiq retries)" do
      stub_request(:post, "#{base_url}/chat/completions").to_return(status: 503, body: "boom")

      expect { client.translate(text: "x", targets: targets) }
        .to raise_error(MultilingualPost::LlmClient::TransientError)
    end

    it "raises a permanent error on 401 (Service Token rejected)" do
      stub_request(:post, "#{base_url}/chat/completions").to_return(status: 401, body: "{}")

      expect { client.translate(text: "x", targets: targets) }
        .to raise_error(MultilingualPost::LlmClient::AuthError)
    end

    it "raises on malformed JSON in LLM output" do
      malformed = {
        choices: [{ message: { role: "assistant", content: "not json at all" } }],
      }.to_json
      stub_request(:post, "#{base_url}/chat/completions").to_return(
        status: 200,
        body: malformed,
        headers: { "Content-Type" => "application/json" },
      )

      expect { client.translate(text: "x", targets: targets) }
        .to raise_error(MultilingualPost::LlmClient::InvalidResponseError)
    end
  end
end
