require 'active_record/connection_adapters/abstract_mysql_adapter'

module ActiveRecord
  module Mysql
    module Awesome
      class ChangeColumnDefinition < Struct.new(:column, :name) #:nodoc:
      end

      class ColumnDefinition < ActiveRecord::ConnectionAdapters::ColumnDefinition
        attr_accessor :auto_increment, :unsigned, :charset, :collation
      end

      class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition
        def initialize(types, name, temporary, options, as = nil)
          super(types, name, temporary, options)
          @as = as
        end

        def primary_key(name, type = :primary_key, options = {})
          options[:auto_increment] ||= type == :bigint
          super
        end

        def new_column_definition(name, type, options) # :nodoc:
          column = super
          column.auto_increment = options[:auto_increment]
          column.unsigned  = options[:unsigned]
          column.charset   = options[:charset]
          column.collation = options[:collation]
          column
        end

        private

        def create_column_definition(name, type)
          ColumnDefinition.new(name, type)
        end
      end

      module SchemaCreation
        def visit_AddColumn(o)
          add_column_position!("ADD #{accept(o)}", column_options(o))
        end

        private

        def visit_ColumnDefinition(o)
          o.sql_type = type_to_sql(o.type.to_sym, o.limit, o.precision, o.scale, o.unsigned)
          column_sql = "#{quote_column_name(o.name)} #{o.sql_type}"
          add_column_options!(column_sql, column_options(o)) unless o.type == :primary_key
          column_sql
        end

        def visit_ChangeColumnDefinition(o)
          change_column_sql = "CHANGE #{quote_column_name(o.name)} #{accept(o.column)}"
          add_column_position!(change_column_sql, column_options(o.column))
        end

        def column_options(o)
          column_options = super
          column_options[:first] = o.first
          column_options[:after] = o.after
          column_options[:auto_increment] = o.auto_increment
          column_options[:primary_key] = o.primary_key
          column_options[:charset]   = o.charset
          column_options[:collation] = o.collation
          column_options
        end

        def add_column_options!(sql, options)
          if options[:charset]
            sql << " CHARACTER SET #{options[:charset]}"
          end
          if options[:collation]
            sql << " COLLATE #{options[:collation]}"
          end
          if options[:primary_key] == true
            sql << " PRIMARY KEY"
          end
          super
        end

        def add_column_position!(sql, options)
          if options[:first]
            sql << " FIRST"
          elsif options[:after]
            sql << " AFTER #{quote_column_name(options[:after])}"
          end
          sql
        end

        def type_to_sql(type, limit, precision, scale, unsigned = false)
          @conn.type_to_sql(type.to_sym, limit, precision, scale, unsigned)
        end
      end

      module Column
        def unsigned?
          sql_type =~ /unsigned/i
        end

        def bigint?
          sql_type =~ /bigint/i
        end

        def auto_increment?
          extra == 'auto_increment'
        end
      end

      if ActiveRecord::VERSION::STRING < "4.2.0"
        def quote(value, column = nil) #:nodoc:
          return super unless column && column.type

          case column.type
          when :datetime, :time
            if value.acts_like?(:time) && value.respond_to?(:usec)
              zone_conversion_method = ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal
              value = value.send(zone_conversion_method) if value.respond_to?(zone_conversion_method)
              result = value.to_s(:db)
              precision = column.precision
              case precision
              when 1..6
                "'#{result}.#{sprintf("%0#{precision}d", value.usec / 10**(6 - precision))}'"
              else
                "'#{result}'"
              end
            else
              super
            end
          else
            super
          end
        end

        module Column
          def extract_limit(sql_type)
            case sql_type
            when /^(?:date)?time/i; nil
            else
              super
            end
          end

          def extract_precision(sql_type)
            case sql_type
            when /^(?:date)?time/i
              $1.to_i if sql_type =~ /\((\d+)(,\d+)?\)/
            else
              super
            end
          end
        end
      else
        protected

        def initialize_type_map(m) # :nodoc:
          super
          register_class_with_precision m, %r(time)i,     MysqlTime
          register_class_with_precision m, %r(datetime)i, MysqlDateTime
        end

        def register_class_with_precision(mapping, key, klass) # :nodoc:
          mapping.register_type(key) do |*args|
            precision = extract_precision(args.last)
            klass.new(precision: precision)
          end
        end

        private

        module TimeValueWithPrecision
          def type_cast_for_database(value)
            if value.acts_like?(:time) && value.respond_to?(:usec)
              zone_conversion_method = ActiveRecord::Base.default_timezone == :utc ? :getutc : :getlocal
              value = value.send(zone_conversion_method) if value.respond_to?(zone_conversion_method)
              result = value.to_s(:db)
              case precision
              when 1..6
                "#{result}.#{sprintf("%0#{precision}d", value.usec / 10**(6 - precision))}"
              else
                result
              end
            else
              super
            end
          end
        end

        class MysqlTime < Type::Time # :nodoc:
          include TimeValueWithPrecision
        end

        class MysqlDateTime < Type::DateTime # :nodoc:
          include TimeValueWithPrecision
        end
      end

      public

      def type_to_sql(type, limit = nil, precision = nil, scale = nil, unsigned = false)
        return "#{type_to_sql(type, limit, precision, scale)} unsigned" if unsigned && type != :primary_key
        case type.to_s
        when 'integer'
          case limit
          when nil, 4, 11; 'int'  # compatibility with MySQL default
          else
            super(type, limit, precision, scale)
          end
        when 'primary_key'
          "#{type_to_sql(:integer, limit, precision, scale, unsigned)} auto_increment PRIMARY KEY"
        when 'datetime', 'time'
          return super(type, limit, precision, scale) unless precision

          native_type = native_database_types[type.to_sym][:name]
          case precision
          when 0..6; "#{native_type}(#{precision})"
          else raise(ActiveRecordError, "No #{native_type} type has precision of #{precision}. The allowed range of precision is from 0 to 6")
          end
        else
          super(type, limit, precision, scale)
        end
      end

      def options_for_column_spec(table_name)
        if collation = select_one("SHOW TABLE STATUS LIKE '#{table_name}'")["Collation"]
          super.merge(collation: collation)
        else
          super
        end
      end

      def column_spec_for_primary_key(column, options)
        spec = {}
        if column.auto_increment?
          return unless column.bigint?
          spec[:id] = ':bigint'
        else
          spec[:id] = column.type.inspect
          spec.merge!(prepare_column_options(column, options).delete_if { |key, _| [:name, :type, :null].include?(key) })
        end
        spec
      end

      def prepare_column_options(column, options) # :nodoc:
        spec = super
        spec[:unsigned] = 'true' if column.unsigned?
        if column.collation && column.collation != options[:collation]
          spec[:collation] = column.collation.inspect
        end
        spec
      end

      def migration_keys
        super | [:unsigned, :collation]
      end

      def table_options(table_name)
        create_table_info = select_one("SHOW CREATE TABLE #{quote_table_name(table_name)}")["Create Table"]

        # strip create_definitions and partition_options
        raw_table_options = create_table_info.sub(/\A.*\n\) /m, '').sub(/\n\/\*!.*\*\/\n\z/m, '').strip

        # strip AUTO_INCREMENT
        raw_table_options.sub(/(ENGINE=\w+)(?: AUTO_INCREMENT=\d+)/, '\1')
      end

      def add_column_sql(table_name, column_name, type, options = {})
        td = create_table_definition(table_name)
        cd = td.new_column_definition(column_name, type, options)
        schema_creation.visit_AddColumn cd
      end

      def change_column_sql(table_name, column_name, type, options = {})
        column = column_for(table_name, column_name)

        unless options_include_default?(options)
          options[:default] = column.default
        end

        unless options.has_key?(:null)
          options[:null] = column.null
        end

        td = create_table_definition(table_name)
        cd = td.new_column_definition(column.name, type, options)
        schema_creation.accept(ChangeColumnDefinition.new(cd, column.name))
      end

      def rename_column_sql(table_name, column_name, new_column_name)
        column  = column_for(table_name, column_name)
        options = {
          default: column.default,
          null: column.null,
          auto_increment: column.auto_increment?
        }

        current_type = select_one("SHOW COLUMNS FROM #{quote_table_name(table_name)} LIKE '#{column_name}'", 'SCHEMA')["Type"]
        td = create_table_definition(table_name)
        cd = td.new_column_definition(new_column_name, current_type, options)
        schema_creation.accept(ChangeColumnDefinition.new(cd, column.name))
      end

      private

      def configure_connection
        _config = @config
        if [':default', :default].include?(@config[:strict])
          @config = @config.deep_merge(variables: { sql_mode: :default })
        end
        super
      ensure
        @config = _config
      end

      def create_table_definition(name, temporary = false, options = nil, as = nil) # :nodoc:
        TableDefinition.new(native_database_types, name, temporary, options, as)
      end
    end
  end

  module ConnectionAdapters
    class AbstractMysqlAdapter < AbstractAdapter
      prepend Mysql::Awesome

      class Column < ConnectionAdapters::Column # :nodoc:
        prepend Mysql::Awesome::Column
      end

      class SchemaCreation < AbstractAdapter::SchemaCreation
        prepend Mysql::Awesome::SchemaCreation
      end
    end
  end
end
