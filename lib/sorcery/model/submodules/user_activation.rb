module Sorcery
  module Model
    module Submodules
      # This submodule adds the ability to make the user activate his account via email
      # or any other way in which he can recieve an activation code.
      # with the activation code the user may activate his account.
      # When using this submodule, supplying a mailer is mandatory.
      module UserActivation
        def self.included(base)
          base.sorcery_config.class_eval do
            # The attribute name to hold activation state (active/pending).
            attr_accessor :activation_state_attribute_name
            # The attribute name to hold activation code (sent by email).
            attr_accessor :activation_token_attribute_name
            # The attribute name to hold activation code expiration date.
            attr_accessor :activation_token_expires_at_attribute_name
            # How many seconds before the activation code expires. nil for never expires.
            attr_accessor :activation_token_expiration_period
            # Your mailer class. Required when activation_mailer_disabled == false.
            attr_accessor :user_activation_mailer
            # When true sorcery will not automatically email activation details and allow you to manually handle how and when email is sent
            attr_accessor :activation_mailer_disabled
            # Activation needed email method on your mailer class.
            attr_accessor :activation_needed_email_method_name
            # Activation success email method on your mailer class.
            attr_accessor :activation_success_email_method_name
            # Do you want to prevent or allow users that did not activate by email to login?
            attr_accessor :prevent_non_active_users_to_login
          end

          base.sorcery_config.instance_eval do
            @defaults.merge!(:@activation_state_attribute_name             => :activation_state,
                             :@activation_token_attribute_name             => :activation_token,
                             :@activation_token_expires_at_attribute_name  => :activation_token_expires_at,
                             :@activation_token_expiration_period          => nil,
                             :@user_activation_mailer                      => nil,
                             :@activation_mailer_disabled                  => false,
                             :@activation_needed_email_method_name         => :activation_needed_email,
                             :@activation_success_email_method_name        => :activation_success_email,
                             :@prevent_non_active_users_to_login           => true)
            reset!
          end

          base.class_eval do
            # don't setup activation if no password supplied - this user is created automatically
            sorcery_adapter.define_callback :before, :create, :setup_activation, if: proc { |user| user.send(sorcery_config.password_attribute_name).present? }
            # don't send activation needed email if no crypted password created - this user is external (OAuth etc.)
            sorcery_adapter.define_callback :after, :commit, :send_activation_needed_email!, on: :create, if: :send_activation_needed_email?
          end

          base.sorcery_config.after_config << :validate_mailer_defined
          base.sorcery_config.after_config << :define_user_activation_fields
          base.sorcery_config.before_authenticate << :prevent_non_active_login

          base.extend(ClassMethods)
          base.send(:include, InstanceMethods)
        end

        module ClassMethods
          # Find user by token, also checks for expiration.
          # Returns the user if token found and is valid.
          def load_from_activation_token(token, &block)
            load_from_token(
              token,
              @sorcery_config.activation_token_attribute_name,
              @sorcery_config.activation_token_expires_at_attribute_name,
              &block
            )
          end

          protected

          # This submodule requires the developer to define his own mailer class to be used by it
          # when activation_mailer_disabled is false
          def validate_mailer_defined
            message = 'To use user_activation submodule, you must define a mailer (config.user_activation_mailer = YourMailerClass).'
            raise ArgumentError, message if @sorcery_config.user_activation_mailer.nil? && @sorcery_config.activation_mailer_disabled == false
          end

          def define_user_activation_fields
            class_eval do
              sorcery_adapter.define_field sorcery_config.activation_state_attribute_name, String
              sorcery_adapter.define_field sorcery_config.activation_token_attribute_name, String
              sorcery_adapter.define_field sorcery_config.activation_token_expires_at_attribute_name, Time
            end
          end
        end

        module InstanceMethods
          def setup_activation
            config = sorcery_config
            generated_activation_token = TemporaryToken.generate_random_token
            send(:"#{config.activation_token_attribute_name}=", generated_activation_token)
            send(:"#{config.activation_state_attribute_name}=", 'pending')
            send(:"#{config.activation_token_expires_at_attribute_name}=", Time.now.in_time_zone + config.activation_token_expiration_period) if config.activation_token_expiration_period
          end

          # clears activation code, sets the user as 'active' and optionaly sends a success email.
          def activate!
            config = sorcery_config
            send(:"#{config.activation_token_attribute_name}=", nil)
            send(:"#{config.activation_state_attribute_name}=", 'active')
            send_activation_success_email! if send_activation_success_email?
            sorcery_adapter.save(validate: false, raise_on_failure: true)
          end

          attr_accessor :skip_activation_needed_email, :skip_activation_success_email

          protected

          # called automatically after user initial creation.
          def send_activation_needed_email!
            generic_send_email(:activation_needed_email_method_name, :user_activation_mailer)
          end

          def send_activation_success_email!
            generic_send_email(:activation_success_email_method_name, :user_activation_mailer)
          end

          def send_activation_success_email?
            !external? &&
              !(sorcery_config.activation_success_email_method_name.nil? || sorcery_config.activation_mailer_disabled == true) &&
              !skip_activation_success_email
          end

          def send_activation_needed_email?
            !external? &&
              !(sorcery_config.activation_needed_email_method_name.nil? || sorcery_config.activation_mailer_disabled == true) &&
              !skip_activation_needed_email
          end

          def prevent_non_active_login
            config = sorcery_config

            if config.prevent_non_active_users_to_login
              unless send(config.activation_state_attribute_name) == 'active'
                return false, :inactive
              end
            end

            true
          end
        end
      end
    end
  end
end
