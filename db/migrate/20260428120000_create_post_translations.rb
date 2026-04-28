# frozen_string_literal: true

class CreatePostTranslations < ActiveRecord::Migration[7.1]
  def change
    create_table :post_translations do |t|
      t.bigint :post_id, null: false
      t.string :locale, limit: 10, null: false
      t.text :raw, null: false
      t.text :cooked
      t.string :source_locale, limit: 10, null: false
      t.string :status, limit: 20, null: false, default: "pending"
      t.text :error_message
      t.timestamps
    end

    add_index :post_translations, %i[post_id locale], unique: true
    add_index :post_translations, :status
    add_foreign_key :post_translations, :posts, on_delete: :cascade
  end
end
