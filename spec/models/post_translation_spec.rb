# frozen_string_literal: true

require "rails_helper"

describe PostTranslation do
  fab!(:post) { Fabricate(:post) }

  it "is invalid without a post_id" do
    record = described_class.new(locale: "en", raw: "x", source_locale: "ja", status: "completed")
    expect(record).not_to be_valid
    expect(record.errors[:post_id]).to be_present
  end

  it "is invalid without a locale" do
    record = described_class.new(post_id: post.id, raw: "x", source_locale: "ja", status: "completed")
    expect(record).not_to be_valid
  end

  it "is invalid with an unsupported locale" do
    record = described_class.new(
      post_id: post.id,
      locale: "klingon",
      raw: "x",
      source_locale: "ja",
      status: "completed"
    )
    expect(record).not_to be_valid
    expect(record.errors[:locale]).to be_present
  end

  it "rejects duplicate (post_id, locale) pairs" do
    described_class.create!(
      post_id: post.id,
      locale: "en",
      raw: "Hello",
      source_locale: "ja",
      status: "completed"
    )
    duplicate = described_class.new(
      post_id: post.id,
      locale: "en",
      raw: "Hi",
      source_locale: "ja",
      status: "completed"
    )
    expect(duplicate).not_to be_valid
  end

  it "treats status 'pending' / 'completed' / 'failed' as valid" do
    %w[pending completed failed].each do |s|
      record = described_class.new(
        post_id: post.id,
        locale: "en-#{s}",
        raw: "x",
        source_locale: "ja",
        status: s
      )
      record.locale = "en"
      record.valid?
      expect(record.errors[:status]).to be_empty
    end
  end

  describe ".upsert_completed" do
    it "creates a row when none exists" do
      expect {
        described_class.upsert_completed(
          post_id: post.id,
          locale: "en",
          raw: "Hello",
          cooked: "<p>Hello</p>",
          source_locale: "ja"
        )
      }.to change(described_class, :count).by(1)

      record = described_class.find_by(post_id: post.id, locale: "en")
      expect(record.status).to eq("completed")
      expect(record.cooked).to eq("<p>Hello</p>")
    end

    it "overwrites raw / cooked when row exists" do
      described_class.create!(
        post_id: post.id,
        locale: "en",
        raw: "Old",
        source_locale: "ja",
        status: "completed"
      )
      described_class.upsert_completed(
        post_id: post.id,
        locale: "en",
        raw: "New",
        cooked: "<p>New</p>",
        source_locale: "ja"
      )
      expect(described_class.find_by(post_id: post.id, locale: "en").raw).to eq("New")
    end
  end
end
