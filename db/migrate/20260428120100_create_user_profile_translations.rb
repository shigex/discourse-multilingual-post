# frozen_string_literal: true

class CreateUserProfileTranslations < ActiveRecord::Migration[7.1]
  def change
    create_table :user_profile_translations do |t|
      t.bigint :user_id, null: false
      t.string :field_name, limit: 50, null: false
      t.string :locale, limit: 10, null: false
      t.text :raw, null: false
      t.string :source_locale, limit: 10, null: false
      t.string :status, limit: 20, null: false, default: "pending"
      t.text :error_message
      t.timestamps
    end

    add_index :user_profile_translations,
              %i[user_id field_name locale],
              unique: true,
              name: "idx_user_profile_translations_unique"
    add_foreign_key :user_profile_translations, :users, on_delete: :cascade
  end
end
