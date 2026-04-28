# frozen_string_literal: true

require "rails_helper"

describe Jobs::TranslatePost do
  fab!(:author) { Fabricate(:user, locale: "ja") }
  fab!(:post) { Fabricate(:post, user: author, raw: "こんにちは、今夜カレー作る人いる？") }

  let(:llm) { instance_double(MultilingualPost::LlmClient) }

  before do
    SiteSetting.multilingual_post_enabled = true
    allow(MultilingualPost::LlmClient).to receive(:from_env).and_return(llm)
  end

  it "creates a completed PostTranslation row per Tier 1 target locale (excluding source)" do
    expected_targets = MultilingualPost::TIER1_LOCALES - %w[ja]
    translations = expected_targets.index_with { |loc| "translated to #{loc}" }

    expect(llm).to receive(:translate)
      .with(text: post.raw, targets: expected_targets)
      .and_return(MultilingualPost::LlmClient::Result.new(
        source_locale: "ja", translations: translations,
      ))

    described_class.new.execute(post_id: post.id)

    expected_targets.each do |loc|
      record = PostTranslation.find_by(post_id: post.id, locale: loc)
      expect(record).to be_present
      expect(record.status).to eq("completed")
      expect(record.raw).to eq("translated to #{loc}")
      expect(record.source_locale).to eq("ja")
    end
  end

  it "publishes a MessageBus event for each completed locale" do
    targets = MultilingualPost::TIER1_LOCALES - %w[ja]
    allow(llm).to receive(:translate).and_return(
      MultilingualPost::LlmClient::Result.new(
        source_locale: "ja",
        translations: targets.index_with { |l| "x" },
      )
    )

    messages = MessageBus.track_publish("/post-translation/#{post.id}") do
      described_class.new.execute(post_id: post.id)
    end

    published_locales = messages.map { |m| m.data[:locale] }
    expect(published_locales).to match_array(targets)
  end

  it "marks rows failed and re-raises on TransientError so Sidekiq retries" do
    allow(llm).to receive(:translate).and_raise(
      MultilingualPost::LlmClient::TransientError, "LLM down"
    )

    expect { described_class.new.execute(post_id: post.id) }
      .to raise_error(MultilingualPost::LlmClient::TransientError)

    # We want the post to *not* show fake completed translations after a failure.
    expect(PostTranslation.where(post_id: post.id, status: "completed")).to be_empty
  end

  it "no-ops if the post is already deleted" do
    post_id = post.id
    post.destroy!
    expect { described_class.new.execute(post_id: post_id) }.not_to raise_error
  end

  it "skips when the plugin is disabled" do
    SiteSetting.multilingual_post_enabled = false
    expect(llm).not_to receive(:translate)
    described_class.new.execute(post_id: post.id)
    expect(PostTranslation.where(post_id: post.id)).to be_empty
  end
end
