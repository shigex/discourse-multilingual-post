# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module MultilingualPost
  # Thin OpenAI-compatible client for the home Mac Mini's vllm-mlx server,
  # exposed via Cloudflare Tunnel and gated by Cloudflare Access service tokens.
  class LlmClient
    class Error < StandardError; end
    class TransientError < Error; end          # 5xx, timeouts → Sidekiq retry
    class AuthError < Error; end               # 401/403 → fix service token
    class InvalidResponseError < Error; end    # LLM returned junk

    Result = Struct.new(:source_locale, :translations, keyword_init: true)

    attr_reader :base_url, :model

    def initialize(base_url:, model:, access_client_id:, access_client_secret:, timeout: 60)
      @base_url = base_url.chomp("/")
      @model = model
      @cf_id = access_client_id
      @cf_secret = access_client_secret
      @timeout = timeout
    end

    def self.from_env
      new(
        base_url: ENV.fetch("TRANSLATION_LLM_BASE_URL"),
        model: ENV.fetch("TRANSLATION_LLM_MODEL"),
        access_client_id: ENV.fetch("TRANSLATION_LLM_CF_ACCESS_CLIENT_ID"),
        access_client_secret: ENV.fetch("TRANSLATION_LLM_CF_ACCESS_CLIENT_SECRET"),
      )
    end

    def translate(text:, targets:)
      body = {
        model: @model,
        messages: [
          { role: "system", content: TranslationPrompt::SYSTEM },
          { role: "user", content: TranslationPrompt.user_message(text: text, targets: targets) },
        ],
        temperature: 0.1,
        response_format: { type: "json_object" },
      }
      response = post_chat_completions(body)
      parse_translations(response, targets)
    end

    private

    def post_chat_completions(body)
      uri = URI("#{@base_url}/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = @timeout
      http.open_timeout = 10

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["CF-Access-Client-Id"] = @cf_id
      req["CF-Access-Client-Secret"] = @cf_secret
      req.body = body.to_json

      begin
        res = http.request(req)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
        raise TransientError, "LLM unreachable: #{e.class}: #{e.message}"
      end

      case res.code.to_i
      when 200..299 then JSON.parse(res.body)
      when 401, 403 then raise AuthError, "LLM auth failed: #{res.code} #{res.body[0, 200]}"
      when 500..599 then raise TransientError, "LLM #{res.code}: #{res.body[0, 200]}"
      else raise Error, "LLM unexpected #{res.code}: #{res.body[0, 200]}"
      end
    end

    def parse_translations(response, targets)
      content = response.dig("choices", 0, "message", "content")
      raise InvalidResponseError, "no choices" if content.blank?

      payload =
        begin
          JSON.parse(content)
        rescue JSON::ParserError => e
          raise InvalidResponseError, "non-JSON output: #{e.message}: #{content[0, 200]}"
        end

      source = payload["source"]
      translations = payload["translations"]
      raise InvalidResponseError, "missing source/translations" unless source && translations.is_a?(Hash)

      Result.new(source_locale: source, translations: translations.slice(*targets))
    end
  end
end
