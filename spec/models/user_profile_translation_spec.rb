# frozen_string_literal: true

require "rails_helper"

describe UserProfileTranslation do
  fab!(:user) { Fabricate(:user) }

  it "is invalid without a user_id" do
    record = described_class.new(
      field_name: "bio_raw",
      locale: "en",
      raw: "x",
      source_locale: "ja",
      status: "completed"
    )
    expect(record).not_to be_valid
  end

  it "is invalid with an unsupported field_name" do
    record = described_class.new(
      user_id: user.id,
      field_name: "credit_card",
      locale: "en",
      raw: "x",
      source_locale: "ja",
      status: "completed"
    )
    expect(record).not_to be_valid
    expect(record.errors[:field_name]).to be_present
  end

  it "rejects duplicate (user_id, field_name, locale) tuples" do
    described_class.create!(
      user_id: user.id,
      field_name: "bio_raw",
      locale: "en",
      raw: "Hello",
      source_locale: "ja",
      status: "completed"
    )
    duplicate = described_class.new(
      user_id: user.id,
      field_name: "bio_raw",
      locale: "en",
      raw: "Hi",
      source_locale: "ja",
      status: "completed"
    )
    expect(duplicate).not_to be_valid
  end
end
