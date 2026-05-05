# frozen_string_literal: true

require "rails_helper"

describe Jobs::TranslateUserProfile do
  fab!(:user) { Fabricate(:user, locale: "ja") }

  let(:llm) { instance_double(MultilingualPost::LlmClient) }
  let(:expected_targets) { MultilingualPost::TIER1_LOCALES - %w[ja] }

  before do
    SiteSetting.multilingual_post_enabled = true
    allow(MultilingualPost::LlmClient).to receive(:from_env).and_return(llm)
    user.user_profile.update!(bio_raw: "東京湾を見ながらカレーを作るのが好きです。")
  end

  def stub_translate(text:, locales: expected_targets, failed: [])
    allow(llm).to receive(:translate)
      .with(text: text, source_locale: "ja", targets: expected_targets)
      .and_return(
        MultilingualPost::LlmClient::Result.new(
          source_locale: "ja",
          translations: locales.index_with { |loc| "#{text} [#{loc}]" },
          failed_targets: failed,
        ),
      )
  end

  it "creates a completed UserProfileTranslation row per Tier 1 target locale (excluding source) for bio_raw" do
    stub_translate(text: user.user_profile.bio_raw)

    described_class.new.execute(user_id: user.id)

    expected_targets.each do |loc|
      record = UserProfileTranslation.find_by(user_id: user.id, field_name: "bio_raw", locale: loc)
      expect(record).to be_present
      expect(record.status).to eq("completed")
      expect(record.raw).to eq("#{user.user_profile.bio_raw} [#{loc}]")
      expect(record.source_locale).to eq("ja")
    end
  end

  it "publishes a MessageBus event for each translated field" do
    user.custom_fields["hobbies"] = "料理、散歩"
    user.custom_fields["stay_period"] = "2026年4月〜2027年3月"
    user.save_custom_fields

    stub_translate(text: user.user_profile.bio_raw)
    stub_translate(text: "料理、散歩")
    stub_translate(text: "2026年4月〜2027年3月")

    messages = MessageBus.track_publish("/user-profile-translation/#{user.id}") do
      described_class.new.execute(user_id: user.id)
    end

    published_fields = messages.map { |m| m.data[:field] }
    expect(published_fields).to match_array(%w[bio_raw hobbies stay_period])
    expect(messages.map { |m| m.data[:user_id] }.uniq).to eq([user.id])
  end

  it "skips fields whose source text is blank without calling the LLM" do
    # Only bio_raw is populated; hobbies/stay_period are blank → must not hit the LLM.
    expect(llm).to receive(:translate).once
      .with(text: user.user_profile.bio_raw, source_locale: "ja", targets: expected_targets)
      .and_return(
        MultilingualPost::LlmClient::Result.new(
          source_locale: "ja",
          translations: expected_targets.index_with { |l| "x" },
          failed_targets: [],
        ),
      )

    described_class.new.execute(user_id: user.id)

    expect(UserProfileTranslation.where(user_id: user.id, field_name: "hobbies")).to be_empty
    expect(UserProfileTranslation.where(user_id: user.id, field_name: "stay_period")).to be_empty
  end

  it "re-raises TransientError so Sidekiq retries" do
    allow(llm).to receive(:translate).and_raise(
      MultilingualPost::LlmClient::TransientError, "LLM down",
    )

    expect { described_class.new.execute(user_id: user.id) }
      .to raise_error(MultilingualPost::LlmClient::TransientError)

    # No completed rows must be left lying around after a transient failure.
    expect(UserProfileTranslation.where(user_id: user.id, status: "completed")).to be_empty
  end

  it "re-raises AuthError so Sidekiq stops and surfaces the bad service token" do
    allow(llm).to receive(:translate).and_raise(
      MultilingualPost::LlmClient::AuthError, "401",
    )

    expect { described_class.new.execute(user_id: user.id) }
      .to raise_error(MultilingualPost::LlmClient::AuthError)
  end

  it "skips a single field on InvalidResponseError but continues with the rest" do
    user.custom_fields["hobbies"] = "料理"
    user.save_custom_fields

    expect(llm).to receive(:translate)
      .with(text: user.user_profile.bio_raw, source_locale: "ja", targets: expected_targets)
      .and_raise(MultilingualPost::LlmClient::InvalidResponseError, "garbage")

    expect(llm).to receive(:translate)
      .with(text: "料理", source_locale: "ja", targets: expected_targets)
      .and_return(
        MultilingualPost::LlmClient::Result.new(
          source_locale: "ja",
          translations: expected_targets.index_with { |l| "cooking [#{l}]" },
          failed_targets: [],
        ),
      )

    described_class.new.execute(user_id: user.id)

    expect(UserProfileTranslation.where(user_id: user.id, field_name: "bio_raw")).to be_empty
    expect(UserProfileTranslation.where(user_id: user.id, field_name: "hobbies").count)
      .to eq(expected_targets.size)
  end

  it "tolerates Result#failed_targets by simply not creating rows for those locales" do
    # Simulate the LLM giving back de+es but failing en, ko, zh-CN, zh-TW, fr.
    succeeded = %w[de es]
    failed = expected_targets - succeeded

    allow(llm).to receive(:translate).and_return(
      MultilingualPost::LlmClient::Result.new(
        source_locale: "ja",
        translations: succeeded.index_with { |l| "ok [#{l}]" },
        failed_targets: failed,
      ),
    )

    described_class.new.execute(user_id: user.id)

    succeeded.each do |loc|
      expect(UserProfileTranslation.find_by(user_id: user.id, field_name: "bio_raw", locale: loc))
        .to be_present
    end
    failed.each do |loc|
      expect(UserProfileTranslation.find_by(user_id: user.id, field_name: "bio_raw", locale: loc))
        .to be_nil
    end
  end

  it "no-ops when the user is already deleted" do
    user_id = user.id
    user.destroy!
    expect(llm).not_to receive(:translate)
    expect { described_class.new.execute(user_id: user_id) }.not_to raise_error
  end

  it "no-ops when the user_profile is missing" do
    user.user_profile.destroy!
    expect(llm).not_to receive(:translate)
    expect { described_class.new.execute(user_id: user.id) }.not_to raise_error
  end

  it "skips when the plugin is disabled" do
    SiteSetting.multilingual_post_enabled = false
    expect(llm).not_to receive(:translate)
    described_class.new.execute(user_id: user.id)
    expect(UserProfileTranslation.where(user_id: user.id)).to be_empty
  end

  it "falls back to SiteSetting.default_locale when user.locale is blank" do
    user.update!(locale: nil)
    SiteSetting.default_locale = "en"

    fallback_targets = MultilingualPost::TIER1_LOCALES - %w[en]
    expect(llm).to receive(:translate)
      .with(text: user.user_profile.bio_raw, source_locale: "en", targets: fallback_targets)
      .and_return(
        MultilingualPost::LlmClient::Result.new(
          source_locale: "en",
          translations: fallback_targets.index_with { |l| "t[#{l}]" },
          failed_targets: [],
        ),
      )

    described_class.new.execute(user_id: user.id)

    record = UserProfileTranslation.find_by(user_id: user.id, field_name: "bio_raw", locale: "ja")
    expect(record).to be_present
    expect(record.source_locale).to eq("en")
  end
end
