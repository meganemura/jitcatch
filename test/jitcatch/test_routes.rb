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

  # Each action is the one `bin/rails routes` printed for these files on
  # Rails 8.1.4.1.
  def test_a_route_takes_its_names_from_the_inflections_and_the_options_rails_reads
    routes = JitCatch::Routes.parse(<<~RUBY, JitCatch::Inflections.read(%(ActiveSupport::Inflector.inflections(:en) do |inflect|\n  inflect.acronym "API"\n  inflect.irregular "cactus", "cacti"\nend\n)))
      Rails.application.routes.draw do
        resources :news, only: %i[index show]
        resources :people, only: %i[index show]
        resources :cacti, only: :show
        resources :equipment, only: %i[index show]
        resources :api_keys, only: :index
        resources :shelves, controller: "racks", only: :show
        resources :photos, as: "images", only: :show
        resources :posts, module: "blog", only: :index
        resource :child, only: :show
        scope "/manage", module: "staff", as: "manage" do
          resources :shifts, only: :create
        end
        scope controller: :pages do
          get "about", action: :about
          get "faq", action: :faq, as: :help
        end
        get "health", controller: :status, action: :check
      end
    RUBY

    {
      "GET news_index_path" => ["NewsController#index"], "GET news_path" => ["NewsController#show"],
      "GET people_path" => ["PeopleController#index"], "GET person_path" => ["PeopleController#show"],
      "GET cactus_path" => ["CactiController#show"], "GET equipment_index_path" => ["EquipmentController#index"],
      "GET equipment_path" => ["EquipmentController#show"], "GET api_keys_path" => ["APIKeysController#index"],
      "GET shelf_path" => ["RacksController#show"], "GET image_path" => ["PhotosController#show"],
      "GET posts_path" => ["Blog::PostsController#index"], "POST manage_shifts_path" => ["Staff::ShiftsController#create"],
      "GET about_path" => ["PagesController#about"], "GET help_path" => ["PagesController#faq"], "GET /faq" => ["PagesController#faq"],
      "GET health_path" => ["StatusController#check"], "GET /people/7" => ["PeopleController#show"], "GET child_path" => ["ChildrenController#show"]
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

  # A block passed with `&` draws its routes at run time, so its routes are
  # unknown, and the routes around it are still read.
  def test_a_block_passed_with_an_ampersand_is_not_read
    routes = JitCatch::Routes.parse(<<~RUBY)
      admin = proc { resources :users }
      Rails.application.routes.draw do
        namespace :admin, &admin
        resources :books, only: :show, &admin
        scope "/shop", &admin
        constraints(&admin)
        get "about", to: "pages#about"
      end
      Rails.application.routes.draw(&admin)
    RUBY

    assert_equal ["BooksController#show"], routes.actions("GET /books/7")
    assert_equal ["PagesController#about"], routes.actions("GET /about")
    assert_equal [], routes.actions("GET /admin/users")
  end

  # A path helper and a URL helper build their URL from one route.
  def test_a_helper_names_the_route_it_builds_a_url_for
    routes = JitCatch::Routes.parse(ROUTES)

    found = %w[book_reviews_path book_url shelve_book_path about_url books profile_path].map { |helper| routes.route_for_helper(helper)&.then { |route| [route.path, route.action] } }
    assert_equal [["/books/:book_id/reviews", "ReviewsController#create"], ["/books/:id", "BooksController#show"],
      ["/books/:id/shelve", "BooksController#shelve"], ["/about", "PagesController#about"], nil, ["/profile", "ProfilesController#update"]], found
  end
end
