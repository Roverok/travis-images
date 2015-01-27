require 'fog'
require 'shellwords'
require 'timeout'

module Travis
  module CloudImages
    class OpenStack
      class VirtualMachine
        attr_reader :server

        def initialize(server)
          @server = server
        end

        def vm_id
          server.id
        end

        def hostname
          server.name
        end

        def ip_address
          server.addresses.values.flatten.detect { |x| x['OS-EXT-IPS:type'] == 'floating' }['addr']
        end

        def username
          'ubuntu'
        end

        def state
          server.state
        end

        def destroy
          server.disassociate_address(ip_address)
          server.destroy
        end

        def create_image(name)
          server.create_image(name)
        end
      end

      attr_reader :account

      def initialize(account)
        @account = account
      end

      # create a connection
      def connection
        @connection ||= Fog::Compute.new(
          provider: :openstack,
          openstack_api_key: config.api_key,
          openstack_username: config.username,
          openstack_auth_url: config.auth_url,
          openstack_tenant: config.tenant
        )
      end

      def servers
        connection.servers.map { |server| VirtualMachine.new(server) }
      end

      def create_server(opts = {})
        user_data  = %Q{#! /bin/bash\nsudo useradd travis -m -s /bin/bash || true\n}
        user_data += %Q{echo travis:#{opts[:password]} | sudo chpasswd\n} if opts[:password]
        user_data += %Q{echo "travis ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers\n}
        user_data += %Q{sudo sed -i 's/PasswordAuthentication no/# PasswordAuthentication no/g' /etc/ssh/sshd_config\n}
        user_data += %Q{sudo service ssh restart}

        server = connection.servers.create(
          name: opts[:hostname],
          flavor_ref: config.flavor_id,
          image_ref: opts[:image_id] || config.image_id,
          key_name: config.key_name,
          nics: [{ net_id: config.internal_network_id }],
          user_data: user_data #sudo cp -R /home/ubuntu/.ssh /home/travis/.ssh\nsudo chown -R travis:travis /home/travis/.ssh"
        )

        server.wait_for { ready? }

        ip = connection.allocate_address(config.external_network_id)

        connection.associate_address(server.id, ip.body["floating_ip"]["ip"])

        vm = VirtualMachine.new(server.reload)

        # VMs are marked as ACTIVE when turned on
        # but they make take awhile to become available via SSH
        retryable(tries: 15, sleep: 6) do
          ::Net::SSH.start(vm.ip_address, 'ubuntu',{ :keys => config.key_file_name, :paranoid => false }).shell
        end

        vm

      rescue
        clean_up
      end

      def save_template(server, desc)
        full_desc = "travis-#{desc}"

        image = server.create_image(full_desc)

        status = Timeout::timeout(1800) do
          while !find_active_template(full_desc)
            sleep(3)
          end
        end

      rescue
        clean_up
      end

      def latest_template_matching(regexp)
        travis_templates.
          sort_by { |t| t.created_at }.reverse.
          find { |t| t.name =~ Regexp.new(regexp) }
      end

      def latest_template(type)
        latest_template_matching(type)
      end

      def latest_template_id(type)
        latest_template(type).id
      end

      def templates
        connection.images
      end

      def travis_templates
        templates.find_all { |t| t.name =~ /^travis-/ }
      end

      def find_active_template(name)
        templates.find { |t| t.name == name && t.status == 'ACTIVE' }
      end

      def clean_up
        connection.servers.each do |server|
          if server.state == 'ACTIVE'
            server.all_addresses.each do |address|
              puts address
              connection.disassociate_address server, address['ip']
              connection.release_address address['ip']
            end
            server.destroy
          end
        end
      end

      def config
        @config ||= Config.new.open_stack[account.to_s]
      end

      def retryable(opts=nil)
        opts = { :tries => 1, :on => Exception }.merge(opts || {})

        begin
          return yield
        rescue *opts[:on]
          if (opts[:tries] -= 1) > 0
            sleep opts[:sleep].to_f if opts[:sleep]
            retry
          end
          raise
        end
      end

    end
  end
end