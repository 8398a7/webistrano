class Stage < ActiveRecord::Base  
  belongs_to :project
  has_and_belongs_to_many :recipes
  has_many :roles, -> { order 'name ASC' }, :dependent => :destroy
  has_many :hosts, -> { uniq }, :through => :roles
  has_many :configuration_parameters, -> { order 'name ASC' }, :dependent => :destroy, :class_name => "StageConfiguration"
  has_many :deployments, -> { order 'created_at DESC' }, :dependent => :destroy
  belongs_to :locking_deployment, :class_name => 'Deployment', :foreign_key => :locked_by_deployment_id 
  
  validates :name, :presence => true, :uniqueness => {:scope => :project_id}, :length => {:maximum => 250}
  validates :project, :presence => true
  validates :locked, :inclusion => {:in => [0,1]}
  validate :guard_valid_email_addresses

  # fake attr (Hash) that hold info why deployment is not possible
  # (think model.errors lite)
  attr_accessor :deployment_problems
  
  
  # wrapper around alert_emails, returns an array of email addresses
  def emails
    self.alert_emails.try(:split, /\s+/) || []
  end
  
  # returns an array of ConfigurationParameters that is a result of the projects configuration overridden by the stage config 
  def effective_configuration(key=nil) 
    project_configs = self.project.configuration_parameters.dup.to_ary
    my_configs = self.configuration_parameters.dup.to_ary
    
    cleaned_project_configs = project_configs.delete_if{|x| my_configs.collect(&:name).collect(&:to_s).include?(x.name.to_s) }
    
    effec_conf = cleaned_project_configs + my_configs
    effec_conf.sort!{|x, y| x.name <=> y.name }

    if key.blank?
      return effec_conf
    else # specific key look up
      effec_conf.delete_if{|x| x.name.to_s != key.to_s}.first
    end
  end
  
  # returns @deployment_problems, but before sets it through `deployment_possible?`
  def deployment_problems
    @deployment_problems = @deployment_problems || {}
    
    deployment_possible?
    
    @deployment_problems
  end
  
  # tells wether a deployment is possible/allowed
  # by checking that all needed roles are present and some
  # essential variables are set
  def deployment_possible?
    # check roles and vars
    needed_roles_present?
    needed_vars_set?
    
    # when there are not deployment_problems, deployment is possible
    @deployment_problems.blank?
  end
  
  def needed_roles_present?
    # for now just check if there are any roles
    if self.roles.empty? 
      self.add_deployment_problem(:roles, 'no hosts are present. You need at least one host.')
    end
  end
  
  def needed_vars_set?
    needed_vars = [:repository, :application]
    needed_vars.each do |key|
      if self.effective_configuration(key).blank?
        self.add_deployment_problem(key, "the configuration parameter '#{key.to_s}' needs to be set.")
      end
    end
  end
  
  # returns an array of all effective configurations that need a prompt
  def prompt_configurations
    res = effective_configuration.delete_if do |config|
      !config.prompt?
    end
  end
  
  # returns an array of all effective configurations that do not need a prompt
  def non_prompt_configurations
    res = effective_configuration.delete_if do |config|
      config.prompt?
    end
  end
  
  def recent_deployments(limit=3)
    self.deployments.order('deployments.created_at DESC').limit(limit).all
  end
  
  # returns a better form of the stage name for use inside Capistrano recipes
  def webistrano_stage_name
    self.name.underscore.gsub(/[^a-zA-Z0-9\-\_]/, '_')
  end
  
  # returns a lists of all availabe tasks for this stage
  def list_tasks
    d = Deployment.new
    d.stage = self
    deployer = Webistrano::Deployer.new(d)
    begin
      deployer.list_tasks.collect { |t| {:name => t.fully_qualified_name, :description => t.description} }.delete_if{|t| t[:name] == 'shell' || t[:name] == 'invoke'}
    rescue Exception => e
      Rails.logger.error("Problem listing tasks of stage #{id}: #{e} - #{e.backtrace.join("\n")} ")
      [{:name => "Error", :description => "Could not load tasks - syntax error in recipe definition?"}]
    end
  end
    
  def lock
    other_self = self.class.find_by(self.id, :lock => true)
    if other_self
      other_self.update_column(:locked, 1)
    end
    self.reload
  end
  
  def unlock
    other_self = self.class.find_by(self.id, :lock => true)
    if other_self
      other_self.update_column(:locked, 0)
      other_self.update_column(:locked_by_deployment_id, nil)
    end
    self.reload
  end
  
  def lock_with(deployment)
    unless self.locked?
      raise ArgumentError, "stage #{self.id.inspect} must be locked before attaching lock_info to it"
    end

    unless deployment.stage_id == self.id
      raise ArgumentError, "deployment does not belong to stage"
    end

    other_self = self.class.lock.find(self.id)
    other_self.update_column(:locked_by_deployment_id, deployment.id)
    self.reload
  end

  def prepare_cloning(other)
    self.name = "Clone of #{other.name}"
    self.alert_emails = other.alert_emails
  end

  def clone(other)
    self.configuration_parameters.destroy_all
    self.recipes.destroy_all
    self.roles.destroy_all

    other.configuration_parameters.each do |conf|
      self.configuration_parameters << StageConfiguration.new(:name => conf.name, :value => conf.value,
                                                              :project_id => conf.project_id,
                                                              :prompt_on_deploy => conf.prompt_on_deploy)
    end

    other.recipes.each do |recipe|
      self.recipes << recipe
    end

    other.roles.each do |role|
      self.roles << Role.new(:name => role.name, :host_id => role.host_id, :primary => role.primary,
                             :no_release => role.no_release, :ssh_port => role.ssh_port, :no_symlink => role.no_symlink)
    end

    self.reload
  end

protected

  def add_deployment_problem(key, desc)
    @deployment_problems = @deployment_problems || {}
    @deployment_problems[key] = desc
  end

private

  EMAIL_BASE_REGEX = '([^@\s\,\<\>\?\&\;\:]+)@((?:[\-a-z0-9]+\.)+[a-z]{2,})'
  EMAIL_REGEX = /^#{EMAIL_BASE_REGEX}$/i
    
  def guard_valid_email_addresses
    unless self.alert_emails.blank?
      self.alert_emails.split(" ").each do |email|
        unless email.match(EMAIL_REGEX)
          self.errors.add('alert_emails', 'format is not valid, please seperate email addresses by space') 
          break
        end
      end
    end
  end

end
