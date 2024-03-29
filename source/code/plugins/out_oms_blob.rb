module Fluent

  class OutputOMSBlob < BufferedOutput

    Plugin.register_output('out_oms_blob', self)
	
    # Endpoint URL ex. localhost.local/api/

    def initialize
      super
	  
      require 'base64'
      require 'json'
      require 'net/http'
      require 'net/https'
      require 'openssl'
      require 'rexml/document'
      require 'securerandom'
      require 'socket'
      require 'uri'
      require_relative 'omslog'
      require_relative 'oms_configuration'
      require_relative 'oms_common'
    end

    config_param :omsadmin_conf_path, :string, :default => '/etc/opt/microsoft/omsagent/conf/omsadmin.conf'
    config_param :cert_path, :string, :default => '/etc/opt/microsoft/omsagent/certs/oms.crt'
    config_param :key_path, :string, :default => '/etc/opt/microsoft/omsagent/certs/oms.key'
    config_param :blob_uri_expiry, :string, :default => '00:10:00'
    config_param :url_suffix_template, :string, :default => "custom_data_type + '/00000000-0000-0000-0000-000000000002/' + OMS::Common.get_hostname + '/' + OMS::Configuration.agent_id + '/' + suffix + '.log'"
    config_param :proxy_conf_path, :string, :default => '/etc/opt/microsoft/omsagent/conf/proxy.conf'

    def configure(conf)
      super
    end

    def start
      super
      @proxy_config = OMS::Configuration.get_proxy_config(@proxy_conf_path)
    end

    def shutdown
      super
    end

    ####################################################################################################
    # Methods
    ####################################################################################################

    # create a HTTP request to GET blob
    # parameters:
    #   uri: URI. blob URI
    # returns:
    #   HTTPRequest. blob GET request
    def create_blob_get_request(uri)
      headers = {}

      req = Net::HTTP::Get.new(uri.request_uri, headers)
      return req
    end # create_blob_get_request

    # create a HTTP request to PUT blob
    # parameters:
    #   uri: URI. blob URI
    #   msg: string. body of the request
    # returns:
    #   HTTPRequest. blob PUT request
    def create_blob_put_request(uri, msg)
      headers = {}
      headers["Content-Type"] = "application/octet-stream"
      headers["Content-Length"] = msg.bytesize.to_s

      req = Net::HTTP::Put.new(uri.request_uri, headers)
      req.body = msg
      return req
    end # create_blob_put_request

    # get the blob SAS URI from ODS
    # parameters:
    #   container_type: string. ContainerType of the data
    #   data_type: string. DataTypeId of the data
    #   custom_data_type: string. CustomDataType of the CustomLog
    #   suffix: string. Suffix of the blob
    # returns:
    #   URI. blob SAS URI
    def get_blob_uri(container_type, data_type, custom_data_type, suffix)
      data_type_id = data_type
      if !custom_data_type.nil?
        data_type_id = "#{data_type}.#{custom_data_type}"
      end

      url_suffix = eval(url_suffix_template)

      data = {
        "ContainerType" => container_type,
        "DataTypeId" => data_type_id,
        "ExpiryDuration" => blob_uri_expiry,
        "Suffix" => url_suffix
      }

      req = OMS::Common.create_ods_request(OMS::Configuration.get_blob_ods_endpoint.path, data)

      ods_http = OMS::Common.create_ods_http(OMS::Configuration.get_blob_ods_endpoint, @proxy_config)
      body = OMS::Common.start_request(req, ods_http)

      # remove the BOM (Byte Order Marker)
      clean_body = body.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace, :replace => "")
      blob_uri_json = JSON.parse(clean_body)
      return URI.parse( blob_uri_json["Uri"] )
    end # get_blob_uri

    # append data to the blob
    # parameters:
    #   uri: URI. blob URI
    #   msgs: string[]. messages
    def append_blob(uri, msgs)
      if msgs.size == 0
        return true
      end

      # concatenate the messages
      msg = ''
      msgs.each { |s| msg << "#{s}\r\n" if s.to_s.length > 0 }

      # get committed blocks
      blocks_committed = get_committed_blocks(uri)

      # append blocks
      # if the msg is longer than 4MB (to be safe, we use 4,000,000), we should break it into multiple blocks
      chunk_size = 4000000
      blocks_uncommitted = []
      while msg.to_s.length > 0 do
        chunk = msg.slice!(0, chunk_size)
        blocks_uncommitted << upload_block(uri, chunk)
      end

      # commit blocks
      commit_blocks(uri, blocks_committed, blocks_uncommitted)
    end # append_blob

    # get committed blocks from the blob
    # parameters:
    #   uri: URI. blob URI
    # returns:
    #   string[]. a list of committed blocks
    def get_committed_blocks(uri)
      blocklist_uri = URI.parse("#{uri.to_s}&comp=blocklist")
      get_blocklist_req = create_blob_get_request(blocklist_uri)
      http = OMS::Common.create_secure_http(blocklist_uri, @proxy_config)
      body = OMS::Common.start_request(get_blocklist_req, http, true)

      blocks_committed = []
      doc = REXML::Document.new body
      doc.elements.each("BlockList/CommittedBlocks/Block/Name") { |element| blocks_committed << element.text }

      return blocks_committed
    end # get_committed_blocks

    # upload one block to the blob
    # parameters:
    #   uri: URI. blob URI
    #   msg: string. block content
    # returns:
    #   string. block id
    def upload_block(uri, msg)
      base64_blockid = Base64.encode64(SecureRandom.uuid)
      append_uri = URI.parse("#{uri.to_s}&comp=block&blockid=#{base64_blockid}")

      put_block_req = create_blob_put_request(append_uri, msg)
      http = OMS::Common.create_secure_http(append_uri, @proxy_config)
      OMS::Common.start_request(put_block_req, http)

      return base64_blockid
    end # upload_block

    # commit blocks of the blob.
    # NOTE: the order of the committed and uncommitted blocks determines the sequence of the file content
    # parameters:
    #   uri: URI. blob URI
    #   blocks_committed: string[]. committed block id list, which already exist
    #   blocks_uncommitted: string[]. uncommitted block id list, which are just uploaded
    def commit_blocks(uri, blocks_committed, blocks_uncommitted)
      doc = REXML::Document.new "<BlockList />"
      blocks_committed.each { |blockid| doc.root.add_element(REXML::Element.new("Committed").add_text(blockid)) }
      blocks_uncommitted.each { |blockid| doc.root.add_element(REXML::Element.new("Uncommitted").add_text(blockid)) }

      commit_msg = doc.to_s

      blocklist_uri = URI.parse("#{uri.to_s}&comp=blocklist")
      put_blocklist_req = create_blob_put_request(blocklist_uri, commit_msg)
      http = OMS::Common.create_secure_http(blocklist_uri, @proxy_config)
      OMS::Common.start_request(put_blocklist_req, http)
    end # commit_blocks

    # parse the tag to get the settings and append the message to blob
    # parameters:
    #   tag: string. the tag of the item
    #   records: string[]. an arrary of data
    def handle_records(tag, records)
      tags = tag.split('.')
      if tags.size >= 4
        # tag should have 6 parts at least:
        # tags[0]: oms
        # tags[1]: blob
        # tags[2]: container type
        # tags[3]: data type

        container_type = tags[2]
        data_type = tags[3]

        if tag.size >= 6
          # extra tags for CustomLog:
          # tags[4]: custom data type
          custom_data_type = tags[4]

          # tags[5..-1]: monitoring file name
          # concat all the rest parts with .
          suffix = Time.now.utc.strftime("d=%Y%m%d/h=%H/")
          tags[5..-1].each { |s| suffix << "#{s}." }
          # remove the last .
          suffix = suffix[0..-2]
        else
          custom_data_type = nil
          suffix = nil
        end
      else
        @log.error "The tag does not have at least 4 parts #{tag}"
      end

      start = Time.now
      blob_uri = get_blob_uri(container_type, data_type, custom_data_type, suffix)
      time = Time.now - start
      @log.info "Success getting the BLOB uri in #{time.round(3)}s"

      start = Time.now
      append_blob(blob_uri, records)
      time = Time.now - start
      @log.info "Success sending the data to BLOB #{time.round(3)}s"

    end # handle_record

    # This method is called when an event reaches to Fluentd.
    # Convert the event to a raw string.
    def format(tag, time, record)
      @log.trace "Buffering #{tag}"
      [tag, record].to_msgpack
    end

    # This method is called every flush interval. Send the buffer chunk to OMS. 
    # 'chunk' is a buffer chunk that includes multiple formatted
    # NOTE! This method is called by internal thread, not Fluentd's main thread. So IO wait doesn't affect other plugins.
    def write(chunk)
      # Quick exit if we are missing something
      if !OMS::Configuration.load_configuration(omsadmin_conf_path, cert_path, key_path)
        raise 'Missing configuration. Make sure to onboard. Will continue to buffer data.'
      end

      # Group records based on their datatype because OMS does not support a single request with multiple datatypes. 
      datatypes = {}
      chunk.msgpack_each {|(tag, record)|
        if !datatypes.has_key?(tag)
          datatypes[tag] = []
        end
        datatypes[tag] << record['message']
      }

      datatypes.each do |tag, records|
        handle_records(tag, records)
      end
    end

  end # Class

end # Module

