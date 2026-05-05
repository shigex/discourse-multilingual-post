#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Standalone smoke test against the live Mac Mini vllm-mlx via Cloudflare Tunnel.
# Runs WITHOUT a Discourse environment — uses stdlib only (Net::HTTP, JSON, URI).
#
# Usage:
#   export TRANSLATION_LLM_BASE_URL=https://llm.kondou.com/v1
#   export TRANSLATION_LLM_MODEL=translategemma-12b-q4
#   export TRANSLATION_LLM_CF_ACCESS_CLIENT_ID=...
#   export TRANSLATION_LLM_CF_ACCESS_CLIENT_SECRET=...
#   ruby spec/manual/live_translation_smoke.rb
#
# Skipped automatically by RSpec (file is not loaded by default).

$LOAD_PATH.unshift(File.expand_path("../../../lib", __FILE__))
require "multilingual_post/translation_prompt"
require "multilingual_post/llm_client"

# Tier 1 locales (PLAN.md). Note: zh-CN is mapped to zh-Hans inside TranslationPrompt.
TIER1 = %w[ja en ko de es zh-CN zh-TW fr]

source = "ja"
text = "今日は天気がいいので、シェアハウスの庭でバーベキューをしませんか？"
targets = TIER1 - [source]

client = MultilingualPost::LlmClient.from_env

puts "Source (#{source}): #{text}"
puts "Targets: #{targets.inspect}"
puts ""

t0 = Time.now
result = client.translate(text: text, source_locale: source, targets: targets)
dt = Time.now - t0

result.translations.each do |loc, translated|
  puts format("[%-6s] %s", loc, translated)
end

unless result.failed_targets.empty?
  puts ""
  puts "FAILED (permanent): #{result.failed_targets.inspect}"
end

puts ""
puts format("Total: %.2fs (%d targets, parallel)", dt, targets.size)
