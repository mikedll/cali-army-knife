
#!/usr/bin/env ruby

ENV['BUNDLE_GEMFILE'] = File.join( File.dirname( File.expand_path( __FILE__ ) ),  "Gemfile" )

require 'rubygems'
require 'bundler'
Bundler.require

require 'active_support/all'
require 'zlib'
require 'digest/md5'

class Aws < Thor

  FILE_BUFFER_SIZE = 40.megabytes
  LOCAL_MOD_KEY = "x-amz-meta-mtime"
  EPSILON = 1.second

  no_tasks do

    def config
      return @config if @config

      @config = {
        :key => ENV["KEY"] || ENV['AMAZON_ACCESS_KEY_ID'], 
        :secret => ENV["SECRET"] || ENV['AMAZON_SECRET_ACCESS_KEY']
      }
      
      config_file = nil
      Pathname.new(Dir.getwd).tap do |here|
        config_file = [["cknife.yml"], ["tmp", "cknife.yml"]].map { |args|
          here.join(*args)
        }.select { |path|
          File.exists?(path) 
        }.first
      end

      if config_file
        begin
          @config.merge!(YAML.load(config_file.read).symbolize_keys!)
        rescue
          say ("Found, but could not parse config: #{config_file}")
        end        
      end

      @config
    end

    def fog_opts
      opts = {
        :provider => 'AWS',
        :aws_access_key_id => config[:key],
        :aws_secret_access_key => config[:secret]
      }      
      opts.merge!({ :region => options[:region] }) if !options[:region].blank?
      opts
    end

    def fog_storage
      return @storage if @storage 
      @storage = Fog::Storage.new(fog_opts)
      begin
        @storage.directories.count # test login
      rescue Excon::Errors::Forbidden => e
        say("Received Forbidden error while accessing account info. Is your key/secret correct?")
        raise SystemExit
      end
      @storage
    end

    def fog_compute
      @compute ||= Fog::Compute.new(fog_opts)
    end

    def fog_cdn
      @cdn ||= Fog::CDN.new(fog_opts)
    end

    def show_buckets
      fog_storage.directories.sort { |a,b| a.key <=> b.key }.each { |b| puts "#{b.key}" }
    end

    def show_servers
      fog_compute.servers.sort { |a,b| a.key_name <=> b.key_name }.each do |s|
        puts "#{s.tags['Name']} (state: #{s.state}): id=#{s.id} keyname=#{s.key_name} dns=#{s.dns_name} flavor=#{s.flavor_id}"
      end
    end
    
    def show_cdns
      puts fog_cdn.get_distribution_list.body['DistributionSummary'].to_yaml
    end

    def with_bucket(bucket_name)
      d = fog_storage.directories.select { |d| d.key == bucket_name }.first
      if d.nil?
        say ("Could not find bucket with name #{bucket_name}")
        return
      end

      say ("Found bucket named #{bucket_name}")
      yield d
    end

    def fog_key_for(target_root, file_path)
      target_root_path_length ||= target_root.to_s.length + "/".length
      relative = file_path[ target_root_path_length, file_path.length]
      relative
    end

    def s3_download(s3_file)
      dir_path = Pathname.new(s3_file.key).dirname
      dir_path.mkpath
      File.open(s3_file.key, "w") do |f|
        f.write s3_file.body
      end      
    end


    def content_hash(file)
      md5 = Digest::MD5.new

      while !file.eof?
        md5.update(file.read(FILE_BUFFER_SIZE))        
      end

      md5.hexdigest
    end

  end

  desc "list_servers", "Show all servers"
  def list_servers
    show_servers
  end

  desc "start_server [SERVER_ID]", "Start a given EC2 server"
  def start_server(server_id)
    s = fog_compute.servers.select { |s| s.id == server_id}.first
    if s
      say("found server. starting/resuming. #{s.id}")
      s.start
      show_servers
    else
      say("no server with that id found. nothing done.")
    end
  end

  desc "stop_server [SERVER_ID]", "Stop a given EC2 server (does not terminate it)"
  def stop_server(server_id)
    s = fog_compute.servers.select { |s| s.id == server_id}.first
    if s
      say("found server. stopping. #{s.id}")
      s.stop
    else
      say("no server with that id found. nothing done.")
    end
  end

  desc "list_cloudfront", "List cloudfront distributions (CDNs)"
  def list_cloudfront
    show_cdns
  end

  desc "create_cloudfront [BUCKET_NAME]", "Create a cloudfront distribution (a CDN)"
  def create_cloudfront(bucket_id)
    fog_cdn.post_distribution({
                            'S3Origin' => {
                              'DNSName' => "#{bucket_id}.s3.amazonaws.com"
                            },
                            'Enabled' => true
                          })

    show_cdns
  end

  desc "list", "Show all buckets"
  method_options :region => "us-east-1"
  def list
    show_buckets
  end

  desc "afew [BUCKET_NAME]", "Show first 5 files in bucket"
  method_options :count => "5"
  def afew(bucket_name)
    d = fog_storage.directories.select { |d| d.key == bucket_name }.first
    if d.nil?
      say ("Found no bucket by name #{bucket_name}")
      return
    end

    i = 0
    d.files.each do |s3_file|
      break if i >= options[:count].to_i
      say("#{s3_file.key}")
      i += 1
    end
  end
  
  desc "download [BUCKET_NAME]", "Download all files in a bucket to CWD. Or one file."
  method_options :region => "us-east-1"
  method_options :one => nil
  def download(bucket_name)
    with_bucket bucket_name do |d|
      if options[:one].nil?
        if yes?("Are you sure you want to download all files into the CWD?", :red)
          d.files.each do |s3_file|
            say("Creating path for and downloading #{s3_file.key}")
            s3_download(s3_file)
          end
        else
          say("No action taken.")
        end
      else
        s3_file = d.files.get(options[:one])
        if !s3_file.nil?
          s3_download(s3_file)
        else
          say("Could not find #{options[:one]}. No action taken.")
        end
      end
    end
  end

  desc "upsync [BUCKET_NAME] [DIRECTORY]", "Push local files matching glob PATTERN into bucket. Ignore unchanged files."
  method_options :public => false
  method_options :region => "us-east-1"
  method_options :noprompt => nil
  method_options :glob => "**/*"
  method_options :backups_retain => false
  method_options :days_retain => 30
  method_options :months_retain => 3
  method_options :weeks_retain => 5
  method_options :dry_run => false
  def upsync(bucket_name, directory)

    say("This is a dry run.") if options[:dry_run]

    if !File.exists?(directory) || !File.directory?(directory)
      say("'#{directory} does not exist or is not a directory.")
      return
    end

    target_root = Pathname.new(directory)

    files = Dir.glob(target_root.join(options[:glob])).select { |f| !File.directory?(f) }.map(&:to_s)
    if !options[:backups_retain] && files.count == 0
      say("No files to upload and no backups retain requested.")
      return
    end

    say("Found #{files.count} candidate file upload(s).")

    spn = dn = sn = un = cn = 0
    with_bucket bucket_name do |d|

      # having a brain fart and cant get this to simplify
      go = false
      if options[:noprompt] != nil
        go = true
      else
        go = yes?("Proceed?", :red)
      end

      if go
        time_marks = []
        immediate_successors = {}
        if options[:backups_retain]
          # inclusive lower bound, exclusive upper bound
          time_marks = []
          Time.now.beginning_of_day.tap do |start|
            options[:days_retain].times do |i|
              time_marks.push(start - i.days)
            end
          end

          Time.now.beginning_of_week.tap do |start|
            options[:weeks_retain].times do |i|
              time_marks.push(start - i.weeks)
            end
          end

          Time.now.beginning_of_month.tap do |start|
            options[:months_retain].times do |i|
              time_marks.push(start - i.months)
            end
          end

          time_marks.each do |tm|
            files.each do |to_upload|
              File.open(to_upload) do |localfile|
                if localfile.mtime >= tm && (immediate_successors[tm].nil? || localfile.mtime < immediate_successors[tm][:last_modified])
                  immediate_successors[tm] = { :local_path => to_upload, :last_modified => localfile.mtime }
                end
              end
            end
          end
        end

        # don't pointlessly upload large files if we already know we're going to delete them!
        if options[:backups_retain] 
          immediate_successors.values.map { |h| h[:local_path] }.tap do |kept_files| 
            before_reject = files.count # blah...lame
            files.reject! { |to_upload| !kept_files.include?(to_upload) } 
            sn += before_reject - files.count 

            say("Found #{files.count} file(s) that meet backups retention criteria for upload. Comparing against bucket...")

          end
        end

        files.each do |to_upload|
          say("#{to_upload} (no output if skipped)...")
          k = fog_key_for(target_root, to_upload)

          existing = d.files.get(k)

          time_mismatch = false
          content_hash_mistmatched = false
          File.open(to_upload) do |localfile|
            time_mismatch = !existing.nil? && (existing.metadata[LOCAL_MOD_KEY].nil? || (Time.parse(existing.metadata[LOCAL_MOD_KEY]) - localfile.mtime).abs > EPSILON)
            if time_mismatch
              content_hash_mistmatched = existing.etag != content_hash(localfile)
            end
          end

          if existing && time_mismatch && content_hash_mistmatched
            if !options[:dry_run]
              File.open(to_upload) do |localfile|
                existing.metadata = { LOCAL_MOD_KEY => localfile.mtime.to_s }
                existing.body = localfile
                existing.save
              end
            end
            say("updated.")
            un += 1
          elsif existing && time_mismatch
            if !options[:dry_run]
              existing.metadata = { LOCAL_MOD_KEY => localfile.mtime.to_s }
              existing.save
            end
            say("updated.")
            un += 1            
          elsif existing.nil?
            if !options[:dry_run]
              File.open(to_upload) do |localfile|
                file = d.files.create(
                                      :key    => k,
                                      :metadata => { LOCAL_MOD_KEY => localfile.mtime.to_s },
                                      :body   => localfile,
                                      :public => options[:public]
                                      )
              end
            end
            say("created.")
            cn += 1
          else
            sn += 1
            # skipped
          end
        end


        if options[:backups_retain]

          say("Fetching remote file metadata.")
          # This array of hashes is computed because we need to do
          # nested for loops of M*N complexity, where M=time_marks
          # and N=files.  We also need to do an remote get call to
          # fetch the metadata of all N remote files (d.files.each
          # will not do this). so, for performance sanity, we cache
          # all the meta data for all the N files.

          file_keys_modtimes = d.files.map { |f| 
            say(f.key)

            md = d.files.get(f.key).metadata
            {
              :key => f.key,
              :last_modified => md[LOCAL_MOD_KEY] ? Time.parse(md[LOCAL_MOD_KEY]) : f.last_modified
            }
          }

          # this generates as many 'kept files' as there are time marks...which seems wrong.
          immediate_successors = {}
          time_marks.each do |tm|
            file_keys_modtimes.each do |fkm|
              if fkm[:last_modified] >= tm && (immediate_successors[tm].nil? || fkm[:last_modified] < immediate_successors[tm][:last_modified])
                immediate_successors[tm] = fkm
              end
            end
          end

          immediate_successors.values.map { |v| v[:key] }.tap do |kept_keys|
            d.files.each do |f|
              # dont even bother considering a delete if this doesnt match the glob
              if File.fnmatch(options[:glob], f.key) 

                say("Considering #{f.key}")

                file_key_modtime = file_keys_modtimes.select { |fkm| fkm[:key] == f.key }.first
                if kept_keys.include?(f.key)
                  say("Remote retained #{f.key}.")
                  spn += 1
                else
                  f.destroy if !options[:dry_run]
                  say("Remote deleted #{f.key}.")
                  dn += 1
                end
              end
            end          
          end
        end
      else
        say ("No action taken.")
      end
    end
    say("Done. #{cn} created. #{un} updated. #{sn} local skipped. #{dn} deleted remotely. #{spn} retained remotely.")
  end

  desc "delete [BUCKET_NAME]", "Destroy a bucket"
  method_options :region => "us-east-1"
  def delete(bucket_name)
    d = fog_storage.directories.select { |d| d.key == bucket_name }.first

    if d.nil?
      say ("Found no bucket by name #{bucket_name}")
      return
    end

    if d.files.length > 0
      say "Bucket has #{d.files.length} files. Please empty before destroying."
      return
    end

    if yes?("Are you sure you want to delete this bucket #{d.key}?", :red)
      d.destroy
      say "Destroyed bucket named #{bucket_name}."
      show_buckets
    else
      say "No action taken."
    end

  end

  desc "create [BUCKET_NAME]", "Create a bucket"
  method_options :region => "us-east-1"
  def create(bucket_name = nil)
    if !bucket_name
      puts "No bucket name given." 
      return
    end

    fog_storage.directories.create(
                                   :key => bucket_name,
                                   :location => options[:region]
                                   )

    puts "Created bucket #{bucket_name}."
    show_buckets
  end

  desc "show [BUCKET_NAME]", "Show info about bucket"
  method_options :region => "us-east-1"
  def show(bucket_name = nil)
    if !bucket_name
      puts "No bucket name given." 
      return
    end

    with_bucket(bucket_name) do |d|
      say "#{d}: "
      say d.location
    end
  end

end

Aws.start
