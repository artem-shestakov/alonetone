# -*- encoding : utf-8 -*-
class UsersController < ApplicationController
  
  before_filter :find_user, :except => [:new, :create]
  before_filter :require_login, :except => [:index, :show, :new, :create, :activate, :bio, :destroy]
  
  def index
    @page_title = "#{params[:sort] ? params[:sort].titleize+' - ' : ''} Musicians and Listeners"
    @tab = 'browse'
    @users = User.includes(:pic).paginate_by_params(params)
    @sort = params[:sort]
    @user_count = User.count
    @active     = User.count(:all, :conditions => "assets_count > 0", :include => :pic)
  end

  def show
    respond_to do |format|
      format.html do
        prepare_meta_tags
        gather_user_goodies
      end
      format.xml { @assets = @user.assets.recent.limit(params[:limit] || 10) }
      format.rss { @assets = @user.assets.recent }
      format.js do  render :update do |page| 
          page.replace 'user_latest', :partial => "latest"
        end
      end
    end
  end
  
  def stats
    @tracks = @user.assets
    respond_to do |format|
      format.html 
      format.xml
    end
  end

  def new
    @user = User.new
    @page_title = "Join alonetone to upload your music in mp3 format"
    flash.now[:error] = "Join alonetone to upload and create playlists (it is quick: about 45 seconds)" if params[:new]
  end
  

  def create
    return false if @@bad_ip_ranges.any?{|cloaked_ip| request.ip.match /^#{cloaked_ip}/  } # check bad ips 
    @user = User.new(params[:user])
    if @user.save_without_session_maintenance
      @user.reset_perishable_token!
      UserNotification.signup(@user).deliver
      flash[:ok] = "We just sent you an email to '#{CGI.escapeHTML @user.email}'.<br/><br/>You just have to click the link in the email, and the hard work is over! <br/> Note: check your junk/spam inbox if you don't see a new email right away.".html_safe
      redirect_to login_url
    else
      render :action => :new
    end
  end
  
  
  def activate
    @user = User.where(:perishable_token => params[:perishable_token]).first
    if logged_in? 
      redirect_to new_user_track_path(current_user), :error => "You are already activated and logged in! Rejoice and upload!"
    elsif @user and @user.activate!
      UserSession.create(@user, false) # Log user in manually
      UserNotification.activation(@user).deliver
      redirect_to new_user_track_path(current_user), :ok => "Whew! All done, your account is activated. Go ahead and upload your first track."
    else
      redirect_to new_user_path, :error => "Hm. Activation didn't work. Sorry about that!"
    end
  end
  
  def edit
  end
  
  def bio
    @page_title = "#{@user.name}'s Profile"
    @mostly_listens_to = @user.mostly_listens_to
  end
  
  def attach_pic
    @pic = @user.build_pic(params[:pic])
    if @pic.save
      flash[:ok] = 'Pic updated!'
    else
      flash[:error] = 'Pic not updated!'      
    end
    redirect_to edit_user_path(@user)
  end
  
  
  def update
    # If the user changes the :block_guest_comments setting then it requires
    # that the cache for all their tracks be invalidated 
    flush_asset_caches = false
    if params[:user][:settings].present? && params[:user][:settings][:block_guest_comments]
      currently_blocking_guest_comments = @user.has_setting('block_guest_comments', 'true')
      flush_asset_caches = params[:user][:settings][:block_guest_comments] == ( currently_blocking_guest_comments ? "false" : "true" )
    end
    if @user.update_attributes(params[:user])
      Asset.update_all( { :updated_at => Time.now }, { :user_id => @user.id } ) if flush_asset_caches
      redirect_to edit_user_path(@user), :ok => "Sweet, updated" 
    else
      flash[:error] =  "Not so fast, young one"
      render :action => :edit
    end
  end
  
  def toggle_favorite
    asset = Asset.find(params[:asset_id])
    return false unless logged_in? && asset # no bullshit
    current_user.toggle_favorite(asset)
    render :nothing => true
  end
  
  def toggle_follow
    current_user.add_or_remove_followee(params[:followee_id])
    render :nothing => true
  end

  def destroy
    if admin_or_owner_with_delete
      flash[:ok] = "The alonetone account #{@user.login} has been permanently deleted."
      @user.destroy # this will run "efficiently_destroy_relations" before_destory callback
      redirect_to logout_path
    else
      redirect_to root_path 
    end
  end
  
  def sudo
    if admin? && params[:id]
      sudo_to(params[:id])
    elsif !admin? && session[:sudo]
      return_from_sudo 
    else
      redirect_to root_path
    end
  end

  protected
  
  def prepare_meta_tags
    @page_title = (@user.name)
    @keywords = "#{@user.name}, latest, upload, music, tracks, mp3, mp3s, playlists, download, listen"      
    @description = "Listen to all of #{@user.name}'s music and albums on alonetone. Download #{@user.name}'s mp3s free or stream their music from the page"
    @tab = 'your_stuff' if current_user == @user
  end 
  
  def gather_user_goodies
    @popular_tracks = @user.assets.limit(5).order('assets.listens_count DESC')
    @assets = @user.assets.limit(5)
    @playlists = @user.playlists.public
    @listens = @user.listened_to_tracks.limit(5)
    @track_plays = @user.track_plays.from_user.limit(10)
    @favorites = @user.tracks.favorites.recent.limit(5)
    @comments = @user.comments.public_or_private(display_private_comments?).limit(5)
    @follows = @user.followees
    @mostly_listens_to = @user.mostly_listens_to
  end
  
  def authorized?
    !dangerous_action? || current_user_is_admin_or_owner?(@user) || @sudo.present? && (action_name == 'sudo')
  end
  
  def dangerous_action?
    %w(destroy update edit create).include? action_name 
  end
  
  def change_user_to(user)
    current_user_session.destroy
    UserSession.create!(user)
    flash[:ok] = "Sudo to #{user.name}"
    redirect_back_or_default 
  end
  
  def sudo_to(user_id)
    user = User.where(:login => params[:id]).first
    logger.warn("SUDO: #{current_user.name} is sudoing to #{user.name}")
    @sudo = session[:sudo] = current_user.id
    change_user_to user
  end
  
  def return_from_sudo
    logger.warn("SUDO: returning to admin account")
    change_user_to User.find(session[:sudo])
    @sudo = session[:sudo] = nil
  end
  
  
  def display_user_home_or_index
    if params[:login] && User.find_by_login(params[:login])
      redirect_to user_home_url(params[:user])
    else
      redirect_to users_url
    end
  end
    
end
