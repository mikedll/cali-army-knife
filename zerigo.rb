#!/usr/bin/env ruby

ENV['BUNDLE_GEMFILE'] = File.join( File.dirname( File.expand_path( __FILE__ ) ),  "Gemfile" )

require 'rubygems'
require 'bundler'
Bundler.require

require 'active_support/all'

class Zerigo < Thor

  ENDPOINT = "https://ns.zerigo.com/api/1.1"
  USERNAME = ENV['ZERIGO_USERNAME']
  PASSWORD = ENV['ZERIGO_PASSWORD']
  DOMAIN = ENV['ZERIGO_DEFAULT_DOMAIN']


  no_tasks do
    def zerigo
      @zerigo ||= RestClient::Resource.new ENDPOINT, USERNAME, PASSWORD
    end

    def show_hosts(response)
      fmt = "%6.5s %30.29s %40.39s %12.11s"

      puts sprintf(fmt, 
                   "Type",
                   "Hostname",
                   "Data",
                   "ID")

      Nokogiri::XML( response.body ).css('host').each do |host|
        puts sprintf(fmt,
                     host.at_css('host-type').text,
                     host.at_css('hostname').text,
                     host.at_css('data').text,
                     host.at_css('id').text)
      end
    end

    def zone
      if @zone.nil?
        zones = []
        response = zerigo['/zones.xml'].get 
        unless response.code.to_s !~ /2\d{2}/
          Nokogiri::XML( response.body ).css('zone').each do |zone|
            zones << {
              :id => zone.css('id').first.text,
              :domain => zone.css('domain').first.text,
            }
          end
        end
        found = zones.select { |z| z[:domain] == DOMAIN }.first
        raise "Unable to find zone matching domain #{DOMAIN}" unless found

        @zone = found[:id]
      end
      @zone
    end
  end

  module HostTypes
    CNAME = "CNAME"
    ARECORD = "A"
    MX = "MX"
  end

  desc "list", "List available host names."
  def list
    response = zerigo["/zones/#{zone}/hosts.xml"].get
    unless response.code.to_s !~ /2\d{2}/
      show_hosts( response )
    end
  end

  desc "create [HOST_NAME]", "Create a host"
  method_options :data => "proxy.heroku.com"
  method_options :host_type => HostTypes::CNAME
  def create(hostname = "")
    new_host = { :data => options[:data], :host_type => options[:host_type], :hostname => hostname }

    response = zerigo["/zones/#{zone}/hosts.xml"].post new_host.to_xml(:root => "host"), :content_type => "application/xml"
    if response.code.to_s =~ /201/
      puts "Created a host."
      show_hosts( response )
    end    
  end


  desc "delete [ID]", "Delete an entry by id"
  def delete(id)
    response = zerigo["/hosts/#{id}.xml"].delete
    if response.code.to_s =~ /200/
      puts "Delete a host with id #{id}"
    end    
  end

end

Zerigo.start
