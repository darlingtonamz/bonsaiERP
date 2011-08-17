# encoding: utf-8
# author: Boris Barroso
# email: boriscyber@gmail.com
class AccountLedger < ActiveRecord::Base

  attr_accessor :ac_id

  acts_as_org
  # callbacks
  before_validation { self.currency_id = account_currency_id unless currency_id.present? }
  before_destroy    { false }
  before_create     { self.creator_id = UserSession.user_id }

  # includes
  include ActionView::Helpers::NumberHelper


  # includes related to the model
  include Models::AccountLedger::Money
  include Models::AccountLedger::Transaction

  OPERATIONS = %w(in out trans)
  OPERATIONS.each do |op|
    class_eval <<-CODE, __FILE__, __LINE__ + 1
      def #{op}?
        "#{op}" == operation
      end
    CODE
  end

  # relationships
  belongs_to :account
  belongs_to :to, :class_name => "Account"
  belongs_to :transaction
  belongs_to :currency

  belongs_to :approver, :class_name => "User"
  belongs_to :nuller,   :class_name => "User"
  belongs_to :creator,  :class_name => "User"

  has_many :account_ledger_details, :dependent => :destroy, :autosave => true
  accepts_nested_attributes_for :account_ledger_details, :allow_destroy => true

  # Validations
  validates_presence_of :to_id, :account_id
  validates_inclusion_of :operation, :in => OPERATIONS
  validates_numericality_of :amount, :greater_than => 0, :if => :new_record?
  validates_numericality_of :exchange_rate, :greater_than => 0

  validates :reference, :length => { :within => 3..150, :allow_blank => false }
  validates :currency_id, :currency => true

  #validate  :number_of_details
  #validate  :total_amount_equal

  # accessible
  attr_accessible :account_id, :to_id, :date, :operation, :reference, :currency_id,
    :amount, :exchange_rate, :description, :account_ledger_details_attributes

  # scopes
  scope :pendent, where(:conciliation => false, :active => true)
  scope :con,     where(:conciliation => true)
  scope :nulled,  where(:active => false)
  scope :active,  where(:active => true)

  # delegates
  # currency
  delegate :name, :symbol, :code, :to => :currency, :prefix => true, :allow_nil => true
  # account
  delegate :currency_id, :name, :original_type, :accountable_type, :accountable, :amount,
    :to => :account, :prefix => true, :allow_nil => true
  # to
  delegate :currency_id, :name, :original_type, :accountable_type, :amount,
    :to => :to, :prefix => true, :allow_nil => true
  # transaction
  delegate :type, :to => :transaction, :prefix => true, :allow_nil => true

 
  def self.pendent?
    pendent.count > 0
  end

  # Determines if the ledger can be nulled
  def can_destroy?
    active? and not(conciliation?)
  end

  # Determines if the account ledger can conciliate
  def can_conciliate?
    not(conciliation?) and active?
  end

  # nulls an account_ledger
  def null_account
    return false if conciliation?

    self.nuller_datetime = Time.now

    self.nuller_id = UserSession.user_id
    self.active    = false
    account_ledger_details.each do |det| 
      det.state = 'nulled'
      det.active = false
    end
  
    if transaction_id.present?
      null_transaction_account
    else
      self.save
    end
  end

  # Creates a hash with the methods
  def create_hash(*methods)
    Hash[ methods.map {|m| [m, self.send(m)] } ]
  end

  # Makes the conciliation to update accounts
  def conciliate_account
    return false unless active?
    return false if conciliation?

    self.approver_datetime = Time.now

    if transaction_id.present?
      conciliate_transaction_account
    else
      account_ledger_details.each do |ac|
        ac.state = "con"
      end
      self.conciliation = true

      self.approver_id = UserSession.user_id

      self.save
    end
  end

  def show_exchange_rate?
    if to_id.present?
      if errors[:to_account].blank? and account.currency_id != to.currency_id
        true
      else
        false
      end
    else
      false
    end
  end

  # Determines in or out depending the related account
  def in_out
    case
    when ( ac_id == account_id and amount > 0) then "in"
    when ( ac_id == account_id and amount < 0) then "out"
    when ( ac_id == to_id and amount > 0)      then "out"
    when ( ac_id == to_id and amount > 0)      then "in"
    end
  end

  def amount_currency
    begin
      amount * exchange_rate
    rescue
      0
    end
  end

  # Returns the amount
  def account_amount
    if ac_id == account_id
      amount
    else
      -amount * exchange_rate
    end
  end

  def related_account
    if transaction_id.present?
      transaction
    elsif ac_id == account_id
      to
    else
      account
    end
  end

  def selected_account
    if ac_id == account_id
      account
    else
      to
    end
  end

  # Finds using the filter
  # @param Integer
  # @param String
  def self.filtered(ac_id, filter = 'all')
    ret = AccountLedger.where("account_id=:ac_id OR to_id=:ac_id", :ac_id => ac_id).includes(:account, :to)

    case filter
      when "nulled" then ret.nulled
      when "con"    then ret.con
      when "uncon"  then ret.pendent
      else "all"
        ret
    end
  end

  # returns the ac_id depending on the type od the account
  def payment_link_id
    if account_accountable_type === "MoneyStore"
      account_id
    else
      to_id
    end
  end

  private

    # The sum should be equal
    def total_amount_equal
      tot = account_ledger_details.inject(0) {|sum, det| sum += det.amount_currency }
      unless tot == 0
        self.errors[:base] << "Existe un error en el balance"
      end
    end

    # There must be at least 2 account details
    def number_of_details
      self.errors[:base] << "Debe seleccionar al menos 2 cuentas" if account_ledger_details.size < 2
    end

end
