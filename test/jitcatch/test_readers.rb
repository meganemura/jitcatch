# frozen_string_literal: true

require_relative "../test_helper"

# `context` lists, per changed value, the code that reads it without
# calling it by name. Each case is a small Rails-shaped history with one
# change of one kind.
class TestReaders < Minitest::Test
  ROUTES = <<~RUBY
    Rails.application.routes.draw do
      resources :branches do
        resources :closures, only: :index
      end
      resources :loans, only: :index
    end
  RUBY
  RECORD = "class ApplicationRecord < ActiveRecord::Base\n  primary_abstract_class\nend\n"
  BRANCH = <<~RUBY
    class Branch < ApplicationRecord
      has_many :closures

      def to_s
        name
      end
    end
  RUBY
  CLOSURES = <<~RUBY
    class ClosuresController < ApplicationController
      before_action :set_branch

      def index
        @closures = @branch.closures
      end

      private

      def set_branch
        @branch = Branch.find(params[:branch_id])
      end
    end
  RUBY
  LOAN = <<~RUBY
    class Loan < ApplicationRecord
      LONG_OVERDUE_DAYS = 30

      scope :long_overdue, -> { where("due_on < ?", LONG_OVERDUE_DAYS.days.ago) }

      def days_late(on)
        (on - due_on).to_i
      end
    end
  RUBY
  LOANS = <<~RUBY
    class LoansController < ApplicationController
      def index
        @loans = Loan.order(:id)
        respond_to do |format|
          format.html
          format.json { render json: @loans }
        end
      end
    end
  RUBY

  def app(repo)
    repo.write("config/routes.rb", ROUTES)
    repo.write("app/models/application_record.rb", RECORD)
    repo.write("app/models/branch.rb", BRANCH)
    repo.write("app/models/loan.rb", LOAN)
    repo.write("app/controllers/closures_controller.rb", CLOSURES)
    repo.write("app/controllers/loans_controller.rb", LOANS)
    repo.write("app/views/branches/show.html.erb", "<h1><%= @branch %></h1>\n<%= link_to \"Closures\", branch_closures_path(@branch) %>\n")
    repo.write("app/views/loans/index.html.erb", "<% @loans.each do |loan| %>\n  <%= loan.days_late(Date.current) %> days\n<% end %>\n")
    repo.write("config/initializers/library.rb", "Rails.application.config.x.renewal_limit = 3\n")
    repo.write("app/services/renewal_cap.rb", "class RenewalCap\n  def limit\n    Rails.application.config.x.renewal_limit\n  end\nend\n")
    repo.commit("App", date: "2026-11-01T00:00:00Z")
    repo.branch("base")
  end

  # The change `edit` makes, committed on top of the app, as `context` reads it.
  def readers_after(edit)
    with_repo do |repo|
      app(repo)
      edit.call(repo)
      repo.commit("Change", date: "2026-11-02T00:00:00Z")
      yield JitCatch::Changes.between(repo.dir, "base", "HEAD", readers: true), repo
    end
  end

  def rows(doc, value)
    doc["readers"]["rows"].select { |row| row["value"] == value }.map { |row| [row["mechanism"], "#{row["file"]}:#{row["line"]}"] }
  end

  def test_a_to_param_that_is_not_the_id_flags_the_url_a_lookup_by_id_reads
    readers_after(->(repo) { repo.write("app/models/branch.rb", BRANCH.sub("  def to_s", "  def to_param\n    code\n  end\n\n  def to_s")) }) do |doc|
      row = doc["readers"]["rows"].find { |found| found["file"] == "app/views/branches/show.html.erb" && found["line"] == 2 }
      assert_equal "route_param_mismatch", row["mechanism"]
      assert_equal "Branch#to_param", row["value"]
      assert_includes row["why"], "ClosuresController#index reads params[:branch_id] by id (Branch.find(params[:branch_id]), app/controllers/closures_controller.rb:11)"
      assert_equal doc["methods"].find { |method| method["name"] == "Branch#to_param" }["id"], row["id"]
      assert_includes row["test"], "whose to_param differs from its id"
    end
  end

  def test_a_to_param_that_returns_the_id_is_a_url_but_no_mismatch
    readers_after(->(repo) { repo.write("app/models/branch.rb", BRANCH.sub("  def to_s", "  def to_param\n    id.to_s\n  end\n\n  def to_s")) }) do |doc|
      assert_includes rows(doc, "Branch#to_param"), ["route_param", "app/views/branches/show.html.erb:2"]
      refute rows(doc, "Branch#to_param").any? { |mechanism, _| mechanism == "route_param_mismatch" }
    end
  end

  # A `to_param` outside any class names no model, so no action looks it up.
  def test_a_to_param_outside_a_class_has_no_param_lookup
    readers_after(->(repo) { repo.write("lib/slug.rb", "def to_param\n  code\nend\n") }) do |doc|
      assert_equal ["#to_param"], doc["readers"]["values"].map { |value| value["value"] }
      assert_equal [], rows(doc, "#to_param").select { |mechanism, _| mechanism == "param_lookup" }
    end
  end

  def test_as_json_is_read_by_render_json
    readers_after(->(repo) { repo.write("app/models/loan.rb", LOAN.sub("  def days_late", "  def as_json(options = nil)\n    super(only: %i[id])\n  end\n\n  def days_late")) }) do |doc|
      assert_includes rows(doc, "Loan#as_json"), ["json_render", "app/controllers/loans_controller.rb:6"]
    end
  end

  def test_a_constant_in_sql_and_a_setting_name_their_readers
    readers_after(lambda { |repo|
      repo.write("app/models/loan.rb", LOAN.sub("LONG_OVERDUE_DAYS = 30", "LONG_OVERDUE_DAYS = 45"))
      repo.write("config/initializers/library.rb", "Rails.application.config.x.renewal_limit = 2\n")
    }) do |doc|
      assert_equal [["sql_constant", "app/models/loan.rb:4"]], rows(doc, "Loan::LONG_OVERDUE_DAYS")
      assert_equal [["config_read", "app/services/renewal_cap.rb:3"]], rows(doc, "config.x.renewal_limit")
      setting = doc["readers"]["values"].find { |value| value["value"] == "config.x.renewal_limit" }
      assert_equal ["config", "modified", nil], setting.values_at("kind", "change", "id")
    end
  end

  def test_a_template_call_is_a_call_site_and_not_repeated_as_a_reader
    readers_after(->(repo) { repo.write("app/models/loan.rb", LOAN.sub("(on - due_on).to_i", "(on - due_on).to_i - 1")) }) do |doc|
      method = doc["methods"].find { |found| found["name"] == "Loan#days_late" }
      assert_includes method["callsites"], { "file" => "app/views/loans/index.html.erb", "line" => 2, "enclosing" => "app/views/loans/index.html.erb" }
      assert_includes method["reachable_from"], "app/views/loans/index.html.erb"
      assert_empty rows(doc, "Loan#days_late")
      assert_includes JitCatch::Render.context_text(doc), "callsites: app/views/loans/index.html.erb:2\n"
    end
  end

  def test_a_bare_call_in_a_template_reaches_only_a_helper
    with_repo do |repo|
      repo.write("app/helpers/loans_helper.rb", "module LoansHelper\n  def due_label(loan)\n    loan.due_on.to_s\n  end\nend\n")
      repo.write("app/models/note.rb", "class Note\n  def title\n    \"note\"\n  end\nend\n")
      repo.write("app/views/loans/show.html.erb", "<%= due_label(@loan) %>\n<%= title %>\n")
      repo.commit("App", date: "2026-11-01T00:00:00Z")
      repo.branch("base")
      repo.write("app/helpers/loans_helper.rb", "module LoansHelper\n  def due_label(loan)\n    loan.due_on.iso8601\n  end\nend\n")
      repo.write("app/models/note.rb", "class Note\n  def title\n    \"a note\"\n  end\nend\n")
      repo.commit("Change", date: "2026-11-02T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD")
      callsites = doc["methods"].to_h { |method| [method["name"], method["callsites"].map { |site| site["line"] }] }
      assert_equal({ "LoansHelper#due_label" => [1], "Note#title" => [] }, callsites)
    end
  end

  def test_a_default_scope_is_read_by_queries_and_associations
    readers_after(lambda { |repo|
      repo.write("app/models/loan.rb", LOAN.sub("  LONG_OVERDUE_DAYS = 30\n", "  LONG_OVERDUE_DAYS = 30\n\n  default_scope { order(due_on: :desc) }\n"))
      repo.write("app/models/member.rb", "class Member < ApplicationRecord\n  has_many :loans\nend\n")
    }) do |doc|
      found = rows(doc, "Loan.default_scope")
      assert_includes found, ["default_scope_order", "app/controllers/loans_controller.rb:3"]
      assert_includes found, ["default_scope_association", "app/models/member.rb:2"]
    end
  end

  def test_to_s_is_read_where_a_page_prints_the_record
    readers_after(->(repo) { repo.write("app/models/branch.rb", BRANCH.sub("    name\n", "    \"\#{name} (\#{code})\"\n")) }) do |doc|
      assert_equal [["to_s_output", "app/views/branches/show.html.erb:1"]], rows(doc, "Branch#to_s")
    end
  end

  def test_a_schema_default_the_change_edits_lists_the_record_made_without_it
    with_repo do |repo|
      repo.write("app/models/application_record.rb", RECORD)
      repo.write("app/models/fine.rb", "class Fine < ApplicationRecord\n  validates :status, inclusion: { in: %w[unpaid paid] }\nend\n")
      repo.write("app/services/fine_desk.rb", "class FineDesk\n  def charge(loan)\n    Fine.create!(loan: loan)\n  end\nend\n")
      repo.write("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"fines\" do |t|\n    t.string \"status\", default: \"unpaid\", null: false\n  end\nend\n")
      repo.commit("App", date: "2026-11-01T00:00:00Z")
      repo.branch("base")
      repo.write("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"fines\" do |t|\n    t.string \"status\", default: \"pending\", null: false\n  end\nend\n")
      repo.commit("Change", date: "2026-11-02T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD", readers: true)
      assert_equal [["default_taker", "app/services/fine_desk.rb:3"], ["validation_reads", "app/models/fine.rb:2"]], rows(doc, "Fine.status default")
    end
  end

  def test_a_renamed_method_is_reached_by_a_built_name
    fine = "class Fine < ApplicationRecord\n  def late_label\n    \"late\"\n  end\nend\n"
    readers_after(lambda { |repo|
      repo.write("app/models/fine.rb", fine.sub("late_label", "overdue_label"))
      repo.write("app/services/fine_totals.rb", "class FineTotals\n  def label(fine)\n    fine.public_send(\"\#{fine.kind}_label\")\n  end\nend\n")
    }) do |doc|
      assert_equal [["dispatch_pattern", "app/services/fine_totals.rb:3"]], rows(doc, "Fine#overdue_label")
    end
  end

  # The constant fixture: a bare STATUSES means the one its class or an
  # ancestor defines, so a class with its own is not a reader.
  def test_a_bare_constant_is_looked_up_lexically_and_through_ancestors
    with_repo do |repo|
      order = "class Order < ApplicationRecord\n  STATUSES = %w[pending paid].freeze\n\n  validates :status, inclusion: { in: STATUSES }\nend\n"
      repo.write("app/models/application_record.rb", RECORD)
      repo.write("app/models/order.rb", order)
      repo.write("app/models/special_order.rb", "class SpecialOrder < Order\n  validates :status, inclusion: { in: STATUSES - %w[cancelled] }\nend\n")
      repo.write("app/models/payment.rb", "class Payment < ApplicationRecord\n  STATUSES = %w[done].freeze\n\n  validates :status, inclusion: { in: STATUSES }\nend\n")
      repo.write("app/models/shipment.rb", "class Shipment < ApplicationRecord\n  validates :order_status, inclusion: { in: STATUSES }\nend\n")
      repo.write("app/controllers/admin/orders_controller.rb", "module Admin\n  class OrdersController < ApplicationController\n    def index\n      @orders = ::Order.where(status: Order::STATUSES)\n    end\n  end\nend\n")
      repo.commit("App", date: "2026-11-01T00:00:00Z")
      repo.branch("base")
      repo.write("app/models/order.rb", order.sub("pending paid", "pending authorized paid"))
      repo.commit("Add the authorized order status", date: "2026-11-02T00:00:00Z")

      doc = JitCatch::Changes.between(repo.dir, "base", "HEAD", readers: true)
      found = doc["readers"]["rows"].map { |row| [row["mechanism"], "#{row["file"]}:#{row["line"]}", row["score"]] }
      assert_equal [
        ["sql_constant", "app/controllers/admin/orders_controller.rb:4", 90],
        ["validation_reads", "app/models/special_order.rb:2", 80],
        ["validation_reads", "app/models/order.rb:4", 70],
        ["validation_reads", "app/models/shipment.rb:2", 30]
      ], found
      assert_equal "bare STATUSES is defined nowhere visible; may reach it through a mixin", doc["readers"]["rows"].last["rank"]
    end
  end

  def test_a_plain_read_inside_a_method_the_constant_lists_is_not_repeated
    readers_after(lambda { |repo|
      repo.write("app/models/loan.rb", LOAN.sub("LONG_OVERDUE_DAYS = 30", "LONG_OVERDUE_DAYS = 45").sub("(on - due_on).to_i", "(on - due_on).to_i - LONG_OVERDUE_DAYS"))
    }) do |doc|
      constant = doc["constants"].find { |const| const["name"] == "Loan::LONG_OVERDUE_DAYS" }
      assert_includes constant["read_by"], doc["methods"].find { |method| method["name"] == "Loan#days_late" }["id"]
      assert_equal [["sql_constant", "app/models/loan.rb:4"]], rows(doc, "Loan::LONG_OVERDUE_DAYS")
    end
  end

  # BASE and HEAD come from git objects, so a checkout of either side, with
  # edits nobody committed, gives the same rows.
  def test_readers_ignore_the_checkout
    readers_after(->(repo) { repo.write("app/models/branch.rb", BRANCH.sub("  def to_s", "  def to_param\n    code\n  end\n\n  def to_s")) }) do |doc, repo|
      repo.checkout("base")
      repo.write("app/views/branches/show.html.erb", "<%= link_to \"x\", branch_path(@branch) %>\n")
      repo.write("app/models/branch.rb", "class Branch < ApplicationRecord\nend\n")
      assert_equal doc["readers"], JitCatch::Changes.between(repo.dir, "base", doc["head"], readers: true)["readers"]
    end
  end

  def test_run_builds_no_readers
    readers_after(->(repo) { repo.write("app/models/loan.rb", LOAN.sub("= 30", "= 45")) }) do |doc, repo|
      refute JitCatch::Changes.between(repo.dir, "base", "HEAD").key?("readers")
      refute_nil doc["readers"]
    end
  end
end
