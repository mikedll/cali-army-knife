require 'open3'
require 'thor'
require 'cknife/config'
require 'cknife/command_line'

module CKnife
  class CKnifeMysql < Thor

    class_option :verbose, :default => false, :type => :boolean, :desc => "Show which commands are invoked, any input given to them, and any output they give back."

    no_tasks do
      def config
        @config ||= Config
      end

      def conf
        @conf ||= {
          :host      => config['mysql.host'] || "localhost",
          :port      => config['mysql.port'] || 3306,
          :database  => config['mysql.database'],
          :username  => config['mysql.username'],
          :password  => config['mysql.password']
        }
      end

      def connection_options
        "--defaults-file=#{option_file} -h #{conf[:host]} -P #{conf[:port]} -u #{conf[:username]}"
      end

      def option_file
        @option_file ||= "my.cnf"
      end

      def command_line
        @command_line ||= CommandLine.new(option_file, "[client]\npassword=\"#{conf[:password]}\"", self, options)
      end

      def mysql_easy
        "mysql #{connection_options} #{conf[:database]}"
      end
    end

    desc "console", "Launch mysql console."
    method_option :myfile, :type => :boolean, :default => false, :desc => "Write my.cnf file if it doesn't exist."
    def console
      if !File.exists?(option_file)
        if !options[:myfile]
          say("You must prepare a #{option_file} file for this command, or use --myfile to have this tool create it for you. Alternatively, you can create a #{option_file} file with the myfile command and delete it later with the dmyfile command.")
          return
        end

        command_line.write_option_file
      end

      dc(mysql_easy) if options[:verbose]
      exec(mysql_easy)
    end

    desc "myfile", "Write a my.cnf file in $CWD. Useful for starting a mysql session on your own."
    def myfile
      command_line.create_opt_file("Connect command: #{mysql_easy}")
    end

    desc "dmyfile", "Delete the my.cnf file in $CWD, assuming it exactly matches what would be generated by this tool."
    def dmyfile
      command_line.delete_opt_file
    end

    desc "capture", "Capture a dump of the database to db(current timestamp).sql."
    def capture
      file_name = "db" + Time.now.strftime("%Y%m%d%H%M%S") + ".sql"

      if File.exists?(file_name)
        say("File already exists: #{file_name}.", :red)
      end

      command_line.with_option_file do |c|
        c.execute "mysqldump #{connection_options} #{conf[:database]} --add-drop-database --result-file=#{file_name}" do
          say("Captured #{file_name}.")
        end
      end
    end

    desc "restore", "Restore a file. Use the one with the most recent mtime by default. Searches for db*.sql files in the CWD."
    method_options :filename => nil
    def restore
      to_restore = options[:filename] if options[:filename]
      if to_restore.nil?
        files = Dir["db*.sql"]
        with_mtime = files.map { |f| [f, File.mtime(f)] }
        with_mtime.sort! { |a,b| a.last <=> b.last }
        files = with_mtime.map(&:first)
        to_restore = files.last
      end

      if to_restore.nil?
        say("No backups file to restore. None given on the command line and none could be found in the CWD.", :red)
        return
      else
        if !yes?("Restore #{to_restore}?", :green)
          return
        end
      end

      command_line.with_option_file do |c|
        say("Doing restore...")

        c.execute("mysql #{connection_options} #{conf[:database]}", "source #{to_restore};") do
          say("Restored #{to_restore}")
        end
      end
    end
  end
end
