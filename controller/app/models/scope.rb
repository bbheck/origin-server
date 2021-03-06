module Scope

  Invalid = Class.new(StandardError)
  Unrecognized = Class.new(StandardError)

  #
  # Return all scopes (with or without values)
  #
  def self.all
    s = scopes.dup
    c = s.delete(nil)
    (c + s.values).map(&:scope_name)
  end

  #
  # Return a valid scope matching the specification
  # or nil
  #
  def self.for(s)
    return nil if s.blank?
    scopes[s] || scopes[nil].find do |scope|
        r = scope.matches?(s)
        return scope.new(r) if r
      end || nil
  end

  #
  # Return a scope matching the specification
  #
  def self.for!(s)
    self.for(s) || (raise Unrecognized, s)
  end

  #
  # Parse a scope spec into scopes or raise an invalid scope error
  #
  def self.list!(spec)
    Scopes.new.concat(
      (spec || '').split(/[,\s]/).
        map!(&:strip).
        delete_if(&:blank?).
        map!(&:downcase).
        uniq.
        map!{ |s| self.for!(s) }
    )
  end

  #
  # Parse a scope spec into scopes or raise an invalid scope error
  #
  def self.list(spec)
    Scopes.new.concat(
      (spec || '').split(/[,\s]/).
        map!(&:strip).
        map!(&:downcase).
        uniq.
        map!{ |s| self.for(s) }.
        compact
    )
  end

  def self.default
    Scope.list(Rails.configuration.openshift[:default_scope])
  end

  def self.describe_all
    scopes.map{ |k,v| v unless k.nil? }.compact.map(&:describe).concat(scopes[nil].map(&:describe)).flatten(1)
  end

  class Base
    def allows_action?(controller)
      false
    end

    def default_expiration
      self.class.default_expiration
    end

    def maximum_expiration
      self.class.maximum_expiration
    end

    def scope_description
      self.class.scope_description
    end

    def describe
      self.class.describe
    end

    def ==(other)
      other.to_s == to_s
    end

    def <=>(other)
      other.to_s <=> to_s
    end

    def as_json(*args)
      to_s
    end

    def self.scope_description
      _description
    end

    def self.describe
      [[scope_name, scope_description, default_expiration, maximum_expiration]]
    end

    protected
      def self.expirations
        @expirations ||= Rails.configuration.openshift[:scope_expirations].freeze
      end

      def self.default_expiration(scope=scope_name)
        @default_expiration ||= (expirations[scope] || expirations[nil]).first
      end

      def self.maximum_expiration(scope=scope_name)
        @maximum_expiration ||= (expirations[scope] || expirations[nil]).last
      end

      class_attribute :_description
      def self.description(desc)
        self._description = desc
      end
  end

  #
  # A scope that is defined by its class name.
  #
  class Simple < Base
    def self.scope_name
      self.name.demodulize.downcase
    end

    def scope_name
      to_s
    end

    def to_s
      self.class.scope_name
    end
  end

  #
  # A scope that has component values. Implement
  # setter methods that validate the string values if your
  # parameters must be checked.  Automatically generates
  # to_s and attribute readers.
  #
  class Parameterized < Base

    protected
      def self.matches(spec)
        metaclass = (class << self; self; end)
        pattern = Regexp.new("\\A#{spec.split(/(\:\w+)/).map{ |s| s[0] == ':' ? "(?<#{s[1..-1]}>[\\w]+)" : Regexp.escape(s) }.join}\\Z")
        to_s_call = spec.gsub(/:\w+/) { |key| "\#{#{key[1..-1]}}" }
        arg = -1
        with_params_call = spec.gsub(/:\w+/) { |key| "\#{args[#{arg += 1}] || ':#{key[1..-1]}'}" }

        metaclass.send(:define_method, :scope_name){ spec }
        define_method(:scope_name){ to_s }
        metaclass.send(:define_method, :matches?){ |s| pattern.match(s) }

        define_method :initialize do |opt|
          pattern.names.map(&:to_sym).each do |k|
            raise Invalid, "#{k} is a required option" if opt[k].blank?
            send(:"#{k}=", opt[k])
          end
        end
        silence_warnings do
          class_eval <<-RUBY_EVAL, __FILE__, __LINE__ + 1
            def to_s() "#{to_s_call}" end
            def self.with_params(*args) "#{with_params_call}" end
          RUBY_EVAL
        end
        attr_reader *pattern.names.map(&:to_sym)
        private
        attr_writer *pattern.names.map(&:to_sym)
      end
  end

  class Scopes < Array
    def as_json(*args)
      to_s
    end
    def to_s
      join(' ')
    end
    def default_expiration
      map(&:default_expiration).min
    end
    def maximum_expiration
      map(&:maximum_expiration).min
    end
  end

  def self.Scopes(arg)
    case arg
    when Scopes then arg
    when String then Scope.list!(arg)
    when Array then Scopes.new.concat(arg)
    else Scopes.new
    end
  end

  protected
    def self.scopes
      @scopes ||= load_scopes(Rails.configuration.openshift[:scopes]).freeze
    end
    def self.load_scopes(classes)
      classes.inject({nil => []}) do |h, c|
        scope_class = c.constantize
        if scope_class.respond_to?(:matches?)
          h[nil] << scope_class
        else
          h[scope_class.scope_name] = scope_class.new
        end
        h
      end
    end
end

module Scope
  SESSION = Scope.list!('session')
  NONE = Scope.list!('')
end
