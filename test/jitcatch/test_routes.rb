# frozen_string_literal: true

require_relative "../test_helper"

class TestRoutes < Minitest::Test
  ROUTES = <<~RUBY
    Rails.application.routes.draw do
      root "pages#home"
      resources :books, only: %i[index create show update] do
        member do
          post :shelve
        end
        post :archive, on: :collection
        resources :reviews, only: :create
      end
      resource :profile, only: :update
      namespace :admin do
        resources :users, except: %i[new edit]
      end
      get "about", to: "pages#about", as: :about
      mount ShelfAPI => "/"
      draw :extra
    end
  RUBY

  # A request names a controller action by the path helper it sends to or
  # by the path itself, as `config/routes.rb` draws them.
  def test_a_request_names_the_controller_action_its_route_draws
    routes = JitCatch::Routes.parse(ROUTES)

    {
      "POST books_path" => ["BooksController#create"],
      "GET books_path" => ["BooksController#index"],
      "PATCH book_path" => ["BooksController#update"],
      "PUT book_path" => ["BooksController#update"],
      "DELETE book_path" => [],
      "POST shelve_book_path" => ["BooksController#shelve"],
      "POST archive_books_path" => ["BooksController#archive"],
      "POST book_reviews_path" => ["ReviewsController#create"],
      "PATCH profile_path" => ["ProfilesController#update"],
      "DELETE admin_user_path" => ["Admin::UsersController#destroy"],
      "GET about_path" => ["PagesController#about"],
      "GET root_path" => ["PagesController#home"],
      "GET /books/7" => ["BooksController#show"],
      "POST /books/*/shelve" => ["BooksController#shelve"],
      "POST */books/*/reviews" => ["ReviewsController#create"],
      "GET /admin/users" => ["Admin::UsersController#index"],
      "GET extra_path" => []
    }.each do |request, actions|
      assert_equal actions, routes.actions(request), request
    end
  end

  # A helper the file does not draw, as one a `draw` file or a loop draws,
  # cannot be read, so the run says so instead of tying the row to nothing.
  def test_a_helper_the_routes_file_does_not_draw_is_unknown
    routes = JitCatch::Routes.parse(ROUTES)

    assert routes.helper?("shelve_book_path")
    refute routes.helper?("extra_path")
    assert_equal [], JitCatch::Routes.parse(nil).actions("GET /books")
  end
end
