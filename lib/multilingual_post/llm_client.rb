# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module MultilingualPost
  # Thin client for the home Mac Mini's vllm-mlx server, exposed via Cloudflare
  # Tunnel and gated by Cloudflare Access service tokens.
  #
  # ## Why /v1/completions and not /v1/chat/completions
  #
  # TranslateGemma 12B uses a specialized chat template that requires per-message
  # `source_lang_code` / `target_lang_code` fields. vllm-mlx's OpenAI-compatible
  # /chat/completions strips non-standard fields before invoking the tokenizer,
  # which causes the template to fail with TemplateError. We render the template
  # ourselves (see TranslationPrompt) and submit raw prompts to /v1/completions.
  #
  # ## One language per call
  #
  # TranslateGemma is purpose-built for translation: each call produces a single
  # target-language output (no JSON-format multi-language response). For N target
  # languages we issue N requests in parallel and aggregate.
  class LlmClient
    class Error < StandardError; end
    class TransientError < Error; end          # 5xx, timeouts → Sidekiq retry
    class AuthError < Error; end               # 401/403 → fix service token
    class InvalidResponseError < Error; end    # LLM returned junk

    Result = Struct.new(:source_locale, :translations, :failed_targets, keyword_init: true)

    DEFAULT_TIMEOUT = 60
    DEFAULT_MAX_TOKENS = 1024

    attr_reader :base_url, :model

    def initialize(base_url:, model:, access_client_id:, access_client_secret:,
                   timeout: DEFAULT_TIMEOUT, max_tokens: DEFAULT_MAX_TOKENS)
      @base_url = base_url.chomp("/")
      @model = model
      @cf_id = access_client_id
      @cf_secret = access_client_secret
      @timeout = timeout
      @max_tokens = max_tokens
    end

    def self.from_env
      new(
        base_url: ENV.fetch("TRANSLATION_LLM_BASE_URL"),
        model: ENV.fetch("TRANSLATION_LLM_MODEL"),
        access_client_id: ENV.fetch("TRANSLATION_LLM_CF_ACCESS_CLIENT_ID"),
        access_client_secret: ENV.fetch("TRANSLATION_LLM_CF_ACCESS_CLIENT_SECRET"),
      )
    end

    # Translate `text` from `source_locale` to each of `targets`.
    #
    # Returns a Result with:
    #   - source_locale: echo of the input (TranslateGemma needs source_locale upfront,
    #     so we don't auto-detect; callers should pass post.user.locale)
    #   - translations: { locale => translated_text } for successful targets
    #   - failed_targets: [locale, ...] for permanent failures (skipped)
    #
    # Raises:
    #   - TransientError if ANY target hits a 5xx / timeout / connection error.
    #     Caller (Sidekiq) should retry the whole job; per-target retry is more
    #     complex and not yet implemented.
    #   - AuthError if the service token is rejected (permanent until fixed).
    def translate(text:, source_locale:, targets:)
      return Result.new(source_locale: source_locale.to_s, translations: {}, failed_targets: []) if text.to_s.strip.empty?
      return Result.new(source_locale: source_locale.to_s, translations: {}, failed_targets: []) if targets.empty?

      results = Hash.new
      failed = []
      transient_errors = []
      auth_error = nil

      threads = targets.map do |target_locale|
        Thread.new do
          [target_locale, translate_one(text: text, source_locale: source_locale, target_locale: target_locale)]
        rescue TransientError => e
          [target_locale, [:transient, e.message]]
        rescue AuthError => e
          [target_locale, [:auth, e.message]]
        rescue InvalidResponseError => e
          [target_locale, [:invalid, e.message]]
        end
      end

      threads.each do |t|
        target, outcome = t.value
        case outcome
        when String
          results[target] = outcome
        when Array
          tag, msg = outcome
          case tag
          when :transient then transient_errors << "#{target}: #{msg}"
          when :auth      then auth_error ||= "#{target}: #{msg}"
          when :invalid   then failed << target
          end
        end
      end

      raise AuthError, auth_error if auth_error
      raise TransientError, transient_errors.join(" | ") if transient_errors.any?

      Result.new(
        source_locale: source_locale.to_s,
        translations: results,
        failed_targets: failed,
      )
    end

    private

    def translate_one(text:, source_locale:, target_locale:)
      prompt = TranslationPrompt.render(
        source_locale: source_locale,
        target_locale: target_locale,
        text: text,
      )

      body = {
        model: @model,
        prompt: prompt,
        max_tokens: @max_tokens,
        temperature: 0.0,
        # TranslateGemma stops cleanly at <end_of_turn>; no extra stop tokens needed.
      }

      response = post_completions(body)
      content = response.dig("choices", 0, "text").to_s.strip
      raise InvalidResponseError, "empty completion for #{target_locale}" if content.empty?
      content
    end

    def post_completions(body)
      uri = URI("#{@base_url}/completions")
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
  end
end
