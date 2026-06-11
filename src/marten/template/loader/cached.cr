module Marten
  module Template
    module Loader
      # A template loader that allows to persist compiled template in a memory cache.
      class Cached < Base
        def initialize(@loaders : Array(Loader::Base))
          @templates_cache = Hash(String, Template).new
          @mutex = Mutex.new
        end

        def get_template(template_name) : Template
          cached = @mutex.synchronize { @templates_cache[template_name]? }
          return cached unless cached.nil?

          # Load/compile outside the lock so concurrent first-renders of *different* templates don't
          # serialize. Two fibers racing on the *same* uncached template may both compile it, but the
          # atomic publish below keeps the cache consistent and every caller gets the same instance.
          template = nil.as(Template?)
          @loaders.each do |loader|
            begin
              template = loader.get_template(template_name)
            rescue Errors::TemplateNotFound
              next
            end

            break unless template.nil?
          end

          if found = template
            return @mutex.synchronize { @templates_cache[template_name] ||= found }
          end

          raise Errors::TemplateNotFound.new("Template #{template_name} could not be found")
        end

        def get_template_source(template_name) : String
          raise NotImplementedError.new("The cached loader does not load template sources directly")
        end
      end
    end
  end
end
