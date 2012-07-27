require 'fileutils'

module ETL #:nodoc:
  class NoLimitSpecifiedError < StandardError; end
  
  class Source < ::ActiveRecord::Base #:nodoc:
    # Connection for database sources
  end
  
  module Control #:nodoc:
    # Source object which extracts data from a database using ActiveRecord.
    class DatabaseSource < Source
      attr_accessor :target
      attr_accessor :table
      
      # Initialize the source.
      #
      # Arguments:
      # * <tt>control</tt>: The ETL::Control::Control instance
      # * <tt>configuration</tt>: The configuration Hash
      # * <tt>definition</tt>: The source definition
      #
      # Required configuration options:
      # * <tt>:target</tt>: The target connection
      # * <tt>:table</tt>: The source table name
      # * <tt>:database</tt>: The database name
      # 
      # Other options:
      # * <tt>:join</tt>: Optional join part for the query (ignored unless 
      #   specified)
      # * <tt>:select</tt>: Optional select part for the query (defaults to 
      #   '*')
      # * <tt>:group</tt>: Optional group by part for the query (ignored 
      #   unless specified)
      # * <tt>:order</tt>: Optional order part for the query (ignored unless 
      #   specified)
      # * <tt>:new_records_only</tt>: Specify the column to use when comparing
      #   timestamps against the last successful ETL job execution for the
      #   current control file.
      # * <tt>:store_locally</tt>: Set to false to not store a copy of the 
      #   source data locally in a flat file (defaults to true)
      def initialize(control, configuration, definition)
        super
        @target = configuration[:target]
        @table = configuration[:table]
        @query = configuration[:query]
      end
      
      # Get a String identifier for the source
      def to_s
        "#{host}/#{database}/#{@table}"
      end
      
      # Get the local directory to use, which is a combination of the 
      # local_base, the db hostname the db database name and the db table.
      def local_directory
        File.join(local_base, to_s)
      end
      
      # Get the join part of the query, defaults to nil
      def join
        configuration[:join]
      end

      # Table to use with the last_completed_id from etl_execution table
      def last_completed_id_table
        configuration[:last_completed_id_table]
      end

      # Maximum rows to be returned per query
      def max_select_size
        configuration[:max_select_size] || 1000000
      end

      # Get the select part of the query, defaults to '*'
      def select
        configuration[:select] || '*'
      end
      
      # Get the group by part of the query, defaults to nil
      def group
        configuration[:group]
      end
      
      # Get the order for the query, defaults to nil
      def order
        configuration[:order]
      end
      
      # Return the column which is used for in the where clause to identify
      # new rows
      def new_records_only
        configuration[:new_records_only]
      end

      def new_records_only_minimum_lag
        configuration[:new_records_only_minimum_lag]
      end

      def use_limit
        configuration[:use_limit].nil? ? true : configuration[:use_limit]
      end

      # Get the number of rows in the source
      def count(use_cache=true)
        return @count if @count && use_cache
        if @store_locally || read_locally
          @count = count_locally
        else
          @count = connection.select_value(query.gsub(/SELECT .* FROM/, 'SELECT count(1) FROM'))
        end
      end
      
      # Get the list of columns to read. This is defined in the source
      # definition as either an Array or Hash
      def columns
        if use_limit && max_select_size
          # pull only 10 cols to get col names
          # weird default is required for writing to cache correctly
          @columns ||= query_rows_with_limit(0, 10).any? ? query_rows_with_limit(0, 10).first.keys : ['']
        else
          # weird default is required for writing to cache correctly
          @columns ||= query_rows.any? ? query_rows.first.keys : ['']
        end
      end
      
      # Returns each row from the source. If read_locally is specified then
      # this method will attempt to read from the last stored local file. 
      # If no locally stored file exists or if the trigger file for the last
      # locally stored file does not exist then this method will raise an
      # error.
      def each(&block)
        if read_locally # Read from the last stored source
          ETL::Engine.logger.debug "Reading from local cache"
          read_rows(last_local_file, &block)
        else # Read from the original source
          if @store_locally
            file = local_file
            write_local(file)
            @query_rows = nil # free the memory
            read_rows(file, &block)
          else
            if use_limit &&  max_select_size
              puts "Doing subselect with starting offset = #{@starting_offset}, max select = #{max_select_size}..."
              rows = query_rows_with_limit(@starting_offset, max_select_size)
              while(rows && rows.size > 0)
                @starting_offset += max_select_size
                rows.each do |row|
                  yield row
                end
                rows = query_rows_with_limit(@starting_offset, max_select_size)
              end
            else
              query_rows.each do |r|
                row = ETL::Row.new()
                r.symbolize_keys.each_pair { |key, value|
                  row[key] = value
                }
                row.source = self
                yield row
              end
            end
          end
        end
      end
      
      private
      # Read rows from the local cache
      def read_rows(file)
        raise "Local cache file not found" unless File.exists?(file)
        raise "Local cache trigger file not found" unless File.exists?(local_file_trigger(file))
        
        t = Benchmark.realtime do
          CSV.open(file, :headers => true).each do |row|
            result_row = ETL::Row.new
            result_row.source = self
            row.each do |header, field|
              result_row[header.to_sym] = field
            end
            yield result_row
          end
        end
        ETL::Engine.average_rows_per_second = ETL::Engine.rows_read / t
      end
      
      def count_locally
        counter = 0
        File.open(last_local_file, 'r').each { |line| counter += 1 }
        counter
      end
      
      # Write rows to the local cache
      def write_local(file)
        lines = 0
        @starting_offset = 0
        t = Benchmark.realtime do
          CSV.open(file, 'w') do |f|
            f << columns
            if use_limit && max_select_size
              rows = query_rows_with_limit(@starting_offset, max_select_size)
              while(rows && rows.size > 0)
                puts "Doing subselect with starting offset = #{@starting_offset}, max select = #{max_select_size}"
                @starting_offset += max_select_size
                rows.each do |row|
                  f << columns.collect { |column| row[column.to_s] }
                  lines += 1
                end
                rows = query_rows_with_limit(@starting_offset, max_select_size)
              end
            else
              puts "No max_select_size given, reading entire table..."
              query_rows.each do |row|
                f << columns.collect { |column| row[column.to_s] }
                lines += 1
              end
            end
          end
          File.open(local_file_trigger(file), 'w') {|f| }
        end
        ETL::Engine.logger.info "Stored locally in #{t}s (avg: #{lines/t} lines/sec)"
      end
      
      # Get the query to use
      def query
        return @query if @query
        q = "SELECT #{select} FROM #{@table}"
        q << " JOIN #{join}" if join
        
        conditions = []
        if new_records_only
          last_completed = ETL::Execution::Job.maximum('created_at', 
            :conditions => ['control_file = ? and completed_at is not null', control.file]
          )
          if last_completed
            cutoff_time = last_completed
            if(new_records_only_minimum_lag)
              cutoff_time = [last_completed, (last_completed - new_records_only_minimum_lag) || last_completed, (Time.now - new_records_only_minimum_lag) || Time.now].min
            end
            conditions << "#{new_records_only} > #{connection.quote(cutoff_time.to_s(:db))}"
          end
        elsif last_completed_id_table
          last_completed = ETL::Execution::Job.maximum('last_completed_id', :conditions => ['control_file = ? and completed_at IS NOT NULL and last_completed_id IS NOT NULL', control.file])
          if(last_completed)
            conditions << "#{last_completed_id_table}.id > #{last_completed}"
          end
        end
        
        conditions << configuration[:conditions] if configuration[:conditions]
        if conditions.length > 0
          q << " WHERE #{conditions.join(' AND ')}"
        end
        
        q << " GROUP BY #{group}" if group
        q << " ORDER BY #{order}" if order
        
        limit = ETL::Engine.limit
        offset = ETL::Engine.offset
        if limit || offset
          raise NoLimitSpecifiedError, "Specifying offset without limit is not allowed" if offset and limit.nil?
          q << " LIMIT #{limit}"
          q << " OFFSET #{offset}" if offset
        end
        
        q = q.gsub(/\n/,' ')
        ETL::Engine.logger.info "Query: #{q}"
        @query = q
      end
      
      def query_rows
        return @query_rows if @query_rows
        if (configuration[:mysqlstream] == true)
          MySqlStreamer.new(query,@target,connection)
        else
          connection.select_all(query)
        end
      end

      def query_rows_with_limit(offset, limit)
        ETL::Engine.logger.debug "query_rows_with_limit called with offset=#{offset}, limit=#{limit}"
        query_string = query + " LIMIT #{offset},#{limit}"
        @query_rows = connection.select_all(query_string)
      end

      # Get the database connection to use
      def connection
        ETL::Engine.connection(target)
      end
      
      # Get the host, defaults to 'localhost'
      def host
        ETL::Base.configurations[target.to_s]['host'] || 'localhost'
      end
      
      def database
        ETL::Base.configurations[target.to_s]['database']
      end
    end
  end
end
