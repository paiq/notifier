/*
 * Paiq notifier framework - http://opensource.implicit-link.com/
 * Copyright (c) 2010 Implicit Link
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef NOTIFIER_H
#define NOTIFIER_H

#include <string>
#include <map>
#include <utility>

#include <boost/function.hpp>
#include <boost/asio.hpp>
#include <boost/bind.hpp>
#include <boost/shared_ptr.hpp>
#include <boost/algorithm/string/join.hpp>

#include "IlmpStream.h"
#include "TokenWalker.h"

#include "dsa_verify.h"

using boost::asio::ip::tcp;

typedef std::pair<int, std::string> User;
typedef enum {
	s_disconnected, // ILMP stream disconnected, no attempt at connecting
	s_connecting,	// Trying to setup ILMP stream or pre-auth while ILMP connected
	s_connected,	// ILMP stream connected, got auth
	s_enabled		// ILMP stream connected, got auth w/userId
} Status;

typedef enum {
	i_msgs, 
	i_users,
	i_normal,
	i_disabled
} Icon;

class Notifier : boost::noncopyable {
protected:
	boost::shared_ptr<IlmpStream> ilmp;
	boost::asio::io_service& ioService; 

	Status status;
	std::string connectError;

	std::string userAgent;
	std::string cookie;
	
	int userId;
	std::string userName;
	int unreadMsgs;
	std::map<int,User> users;
	
	int maleUsers;
	int femaleUsers;
	int onlineUsers;
	
	bool isUpdating;

	void sout(const std::string& msg)
	{
		if (ilmp) (IlmpCommand(ilmp.get(), "Notifier.log") << msg << 0).send();
		std::cout << msg << std::endl;
	}

	void serr(const std::string& msg)
	{
		if (ilmp) (IlmpCommand(ilmp.get(), "Notifier.log") << msg << 1).send();
		std::cerr << msg << std::endl;
	}

private:
	bool isEnabled;
		// Whether we should try to get ourself a userId associated. When !isEnabled, we
		// still connect to get the notifier stats.

	int retryTime;
	int retries;

	std::auto_ptr<boost::asio::deadline_timer> reconnectTimer;
	void onIlmpError(int e, const std::string& msg)
	{
		toStatus(s_disconnected);
		
		if (e == ILMPERR_PROTOVER) {
			// msg contains updateUrl
			// Update push on ILCS protocol level.
			std::cerr << "Protocol version error." << std::endl;
			needUpdate(msg);
		}
		else if (e == ILMPERR_PROTOCOL) {
			std::cerr << "Protocol error: " << msg << ". " << (retries--) << " tries left before giving up." << std::endl;
			if (retries > 0) connect();
		}
		else { //(e == ILMPERR_NETWORK)
			if (ilmp && ilmp->wasConnected) retryTime = 5;
			else retryTime = std::min(60*10, retryTime*2); // Maximum of 10 minutes.

			std::cerr << "Ilmp error: " << msg << "; reconnecting in " << retryTime << " seconds." << std::endl;
			std::stringstream connectErrorMsg;
			connectErrorMsg << "Fout bij verbinden: " << msg;
			connectError = connectErrorMsg.str();
			dataChanged();

			reconnectTimer.reset(new boost::asio::deadline_timer(ioService));
			reconnectTimer->expires_from_now(boost::posix_time::seconds(retryTime));
			reconnectTimer->async_wait(boost::bind(&Notifier::onReconnectTimer, this, boost::asio::placeholders::error));
		}
	}

	void onReconnectTimer(const boost::system::error_code& err)
	{
		if (!ilmp || err == boost::asio::error::operation_aborted)
			return;
			
		connect();
	}

	void onIlmpReady()
	{
		cookie = getConfigValue("cookie");

		(IlmpCommand(ilmp.get(), "User.client") << cookie << userAgent << boost::bind(&Notifier::cbClient, this, _1) << 8).send();
		(IlmpCommand(ilmp.get(), "Notifier.streamStats") << boost::bind(&Notifier::cbStats, this, _1)).send();
	}

	void connect()
	{
		reconnectTimer.reset();

		if (ilmp) {
			ilmp->close();
			ilmp.reset();
		}
		
		toStatus(s_connecting);

		ilmp = boost::shared_ptr<IlmpStream>(new IlmpStream(ioService, ILMPHOST, ILMPPORT, ILMPSITEDIR));
		ilmp->onReady = boost::bind(&Notifier::onIlmpReady, this);
		ilmp->onError = boost::bind(&Notifier::onIlmpError, this, _1, _2);

		ilmp->connect();
	}

	void cbClient(StringTokenWalker& params)
	{
		std::string cmd; params.next(cmd);
		
		if (cmd == "auth") {
			params.next(cookie);
			params.next(userId);
			std::string challenge; params.next(challenge);
			
			setConfigValue("cookie", cookie);
			connectError = "";
			toStatus(s_connected);

			// Depending on whether we have a userId now and we want to be enabled (isEnabled),
			// we might want to open our authorization page or subscribe to Notifier.streamUser.
			setEnabled(isEnabled, false);
		}
		else if (cmd == "popup") {
			std::string msg; params.tryNext(msg);
			std::string url; params.tryNext(url);
			std::string title; params.tryNext(title, SITENAME);
			int sticky; params.tryNext(sticky);
			int prio; params.tryNext(prio);
			
			notify(msg.length() ? title : "", msg, url, !!sticky, !!prio);
		}
		else if (cmd == "reload") {
			std::cout << "Got 'reload' command; scheduling reconnect" << std::endl;
			
			notify(SITENAME, "Sessie afgesloten door de server", "", false, true);
			setConfigValue("enabled", "false");
			userCb = 0;
			ioService.post(boost::bind(&Notifier::reconnect, this));
		}
		else if (cmd == "update") {
			// Update push on backend protocol level.
			std::string updateUrl; params.tryNext(updateUrl, "");
			needUpdate(updateUrl);
		}
		else
			std::cerr << "Unknown command from ILCS on client callback: " << cmd << std::endl;
	}
	
	IlmpCallback* userCb;
	void cbUser(StringTokenWalker& params) {
		std::string cmd; params.next(cmd);
		
		bool hadUsers = !!users.size();
		bool hadMsgs = !!unreadMsgs;
		
		std::string openUrl("http://" SITEHOST "/chat");

		if (cmd == "welcome") {
			params.skip(); // unused, used to be online users.
			params.next(unreadMsgs);
			params.skip(); // unused, used to be sd state.
			params.next(userName);
			
			notify(SITENAME, "De notifier is nu online", openUrl, false, true);
			toStatus(s_enabled);
			return;
		}
		else if (cmd == "online") {
			std::string name; params.next(name);
			int id; params.next(id);
			bool wasOnline = (users.find(id) != users.end());
			users[id] = User(id, name);
			if (!wasOnline) {
				std::stringstream msg; msg << name << " is nu online";
				notify(SITENAME, msg.str(), openUrl, false, false);
			}
		}
		else if (cmd == "offline") {
			std::string name; params.next(name);
			int id; params.next(id);
			users.erase(id);
		}
		else if (cmd == "msg") {
			std::string name; params.next(name);
			unreadMsgs++;
			std::stringstream msg; msg << "Nieuw bericht van " << name;
			notify(SITENAME, msg.str(), openUrl, false, false);
		}
		else if (cmd == "smsg") {
			unreadMsgs++;
		}
		else if (cmd == "read") {
			int readMsgs; params.next(readMsgs);
			unreadMsgs -= readMsgs;
		}
		else if (cmd == "popup") {
			std::string msg; params.tryNext(msg);
			std::string url; params.tryNext(url);
			std::string title; params.tryNext(title, SITENAME);
			int sticky; params.tryNext(sticky);
			int prio; params.tryNext(prio);
			
			notify(msg.length() ? title : "", msg, url, !!sticky, !!prio);
		}
		else {
			std::cerr << "Unknown command from ILCS on streamUser callback: " << cmd << std::endl;
			return;
		}
		
		dataChanged();
		
		if (hadUsers != !!users.size() || hadMsgs != !!unreadMsgs)
			statusChanged();
	}

	void cbStats(StringTokenWalker& params)
	{
		std::string cmd; params.next(cmd);
		
		if (cmd == "stats") {
			params.next(onlineUsers);
			params.next(maleUsers);
			params.next(femaleUsers);
			
			dataChanged();
		}
		else {
			std::cerr << "Unknown command from ILCS on streamStats callback: " << cmd << std::endl;
			return;
		}
	}
	
	void toStatus(Status s) {
		Status oldStatus = status;
		status = s;
		if (oldStatus != status) {
			if (status != s_enabled) {
				users.clear();
				unreadMsgs = 0;
			}
			dataChanged();
			statusChanged();
		}
	}

	boost::asio::io_service::work *waitForInit;
public:
#ifndef USERAGENT
	#define USERAGENT "Notifier [unknown; " __DATE__ ", " __TIME__ "]"
#endif
	Notifier(boost::asio::io_service& ioService_) : ioService(ioService_), isEnabled(true),
			userAgent(USERAGENT), cookie(""), userId(0),
			userName(""), unreadMsgs(0), maleUsers(0), femaleUsers(0), onlineUsers(0),
			status(s_disconnected), retryTime(5), retries(3), userCb(0), reconnectTimer(),
			isUpdating(false) {

		waitForInit = new boost::asio::io_service::work(ioService);
	}

	virtual void initialize() {
#ifdef DEBUG
		std::cout << "initialize" << std::endl;
#endif
		delete waitForInit;
		connect();
	}

	void setEnabled(bool enabled, bool userAction)
	{
#ifdef DEBUG
		std::cout << "setEnabled " << enabled << std::endl;
#endif

		isEnabled = enabled;
		
		if (status == s_disconnected) reconnect();
		else if (status != s_connecting) {

			// Deregister our callback when it exists while we should not be
			// associated with a user.
			if (!(isEnabled && userId) && userCb) {
				userCb->cancel();
				notify(SITENAME, "De notifier is nu uitgelogd", "", false, true);
			}

			if (isEnabled && !userId) {
				std::stringstream loginUrl; loginUrl << "http://" SITEHOST "/authorize?c=" << cookie;
				if (userAction) openUrl(loginUrl.str());
				else notify(SITENAME, "De notifier is uitgelogd, klik hier om in te loggen", loginUrl.str(), true, true);
			}
			else if (isEnabled && !userCb)
				(IlmpCommand(ilmp.get(), "Notifier.streamUser") << boost::bind(&Notifier::cbUser, this, _1) >> &userCb).send();

			if (!isEnabled) toStatus(s_connected);
				// To accomodate the s_enabled > s_connected transition. s_connected > s_enabled is
				// done through the server's welcome msg.
		}
	}

	void reconnect()
	{
		retryTime = 5;
		connect();
	}

	virtual void quit()
	{
		if (ilmp) ilmp->close();
		ilmp.reset();
		reconnectTimer.reset();
	}

	void open()
	{
		openUrl("http://" SITEHOST "/chat");
	}

	void about()
	{
		std::stringstream msg;
		msg << SITENAME << " Notifier\n"
			<< "User-Agent \"" << userAgent << "\"\n" 
			<< "Compiled at " << __DATE__ << ", " << __TIME__ << "\n"
			<< "\n"
			<< "Copyright 2005-2010 Implicit-Link";
		notify(SITEEXTNAME, msg.str(), "http://opensource.implicit-link.com/", false, true);
	}

	// Invoked when any of status, !!users.size(), !!unreadMsgs changes.
	virtual void statusChanged()
	{
		if (unreadMsgs) icon(i_msgs);
		else if (users.size()) icon(i_users);
		else if (status == s_enabled) icon(i_normal);
		else icon(i_disabled);
	}

	// Invoked when any of status, maleUsers, femaleUsers, onlineUsers, isUpdating, users, unreadMsgs changes
	virtual void dataChanged()
	{
		std::list<std::string> ttItems;
		
		if (isUpdating)
			ttItems.push_back("Bezig met updaten...");
		
		std::stringstream statusStr;
		statusStr << SITENAME " notifier: ";
		if (status == s_disconnected) statusStr << "offline";
		else if (status == s_connecting) statusStr << "verbinding maken";
		else if (status == s_connected) statusStr << "uitgelogd";
		else statusStr << "online (" << userName << ")";
		
		ttItems.push_back(statusStr.str());
		
		if (connectError.size())
			ttItems.push_back(connectError);

		if (unreadMsgs > 0) {
			std::stringstream unreadStr;
			unreadStr << unreadMsgs << (unreadMsgs == 1 ? " nieuw bericht" : " nieuwe berichten");
			ttItems.push_back(unreadStr.str());
		}

		if (users.size() > 0) {
			std::list<std::string> userNames;
			for (std::map<int,User>::iterator i = users.begin(); i != users.end(); i++) {
				userNames.push_back((*i).second.second);
			}
			
			std::stringstream onlineStr;
			onlineStr << users.size() << (users.size() == 1 ? " contact online (" : " contacten online (")
			          << boost::algorithm::join(userNames, ", ") << ")";
					
			ttItems.push_back(onlineStr.str());
		}
		
		if (status == s_connected || (status == s_enabled && ttItems.size() <= 1)) {
			std::stringstream statsStr;
			statsStr << (maleUsers + femaleUsers) << " leden, " << onlineUsers << " online";
			ttItems.push_back(statsStr.str());
		}

		tooltip(ttItems);
	}

	virtual void openUrl(const std::string&) { }
	virtual void notify(const std::string& title, const std::string& text, const std::string& url, bool sticky, bool prio) { }
	virtual void icon(Icon i) { }
	virtual void tooltip(const std::list<std::string>& items) { }

	virtual void needUpdate(const std::string& url) {}
	
	virtual std::string getConfigValue(const std::string& name) { return ""; }
	virtual bool setConfigValue(const std::string& name, const std::string& value) { return false; }
	
	// Update logic {{{
	
	// Http fetcher {{{
	typedef boost::function<void(boost::asio::streambuf*)> FetchCallback;
		
	void fetch(std::string &host, std::string &port, std::string &path, FetchCallback cb)
	{
		// Asynchronous http fetch		
		tcp::resolver *resolver = new tcp::resolver(ioService);
		
		tcp::resolver::query query(host, port);
		resolver->async_resolve(query, boost::bind(&Notifier::fetchOnResolve, this,
				resolver, host, path, cb, boost::asio::placeholders::error, boost::asio::placeholders::iterator));
	}
	
	void fetchOnResolve(tcp::resolver *resolver, std::string &host, std::string &path, FetchCallback cb,
			const boost::system::error_code& err, tcp::resolver::iterator endpoint_itr)
	{
		if (err) {
			if (err == boost::asio::error::operation_aborted) std::cerr << "Fetcher: aborted" << std::endl;
			else std::cerr << "Fetcher: unable to resolve hostname" << std::endl;
			
			delete resolver;
			cb(0);
			return;
		}
		
		tcp::socket *socket = new tcp::socket(ioService);
		
		tcp::endpoint endpoint = *endpoint_itr;
		socket->async_connect(endpoint, boost::bind(&Notifier::fetchOnConnect, this,
				resolver, socket, host, path, cb, boost::asio::placeholders::error, ++endpoint_itr));
	}
	
	void fetchOnConnect(tcp::resolver *resolver, tcp::socket *socket, std::string &host, std::string &path,
			FetchCallback cb, const boost::system::error_code& err, tcp::resolver::iterator endpoint_itr)
	{
		if (err == boost::asio::error::operation_aborted) {
			std::cerr << "Fetcher: aborted" << std::endl;
			delete resolver;
			delete socket;
			cb(0);
			return;
		}
		else if (err && endpoint_itr != tcp::resolver::iterator()) {
			// Connection failed, but we can try the next endpoint.
			socket->close();
			tcp::endpoint endpoint = *endpoint_itr;
			std::cerr << "Fetcher: unable to connect to '" << endpoint << "'; trying next endpoint" << std::endl;
			socket->async_connect(endpoint, boost::bind(&Notifier::fetchOnConnect, this,
					resolver, socket, host, path, cb, boost::asio::placeholders::error, ++endpoint_itr));
			return;
		}
		
		delete resolver;
		
		boost::asio::streambuf request;
		std::ostream request_stream(&request);
		request_stream << "GET " << path << " HTTP/1.0\r\n";
		request_stream << "Host: " << host << "\r\n";
		request_stream << "Connection: close\r\n\r\n";
		boost::asio::write(*socket, request);
		
		boost::asio::streambuf* responseBuf = new boost::asio::streambuf;

		// Read headers
		boost::asio::async_read_until(*socket, *responseBuf, "\r\n\r\n", boost::bind(&Notifier::fetchOnHeaders,
				this, socket, responseBuf, cb, boost::asio::placeholders::error, boost::asio::placeholders::bytes_transferred));
	}
	
	void fetchOnHeaders(tcp::socket *socket, boost::asio::streambuf* responseBuf, FetchCallback cb,
			const boost::system::error_code& err, std::size_t transferred)
	{
		if (err) {
			if (err == boost::asio::error::operation_aborted) std::cerr << "Fetcher: aborted" << std::endl;
			else if (err == boost::asio::error::eof) std::cerr << "Fetcher: unexpected EOF" << std::endl;
			else std::cerr << "Fetcher: unable to read data from socket" << std::endl;
			
			delete socket;
			delete responseBuf;
			cb(0);
			return;
		}
		
		responseBuf->consume(transferred); // Discard headers
		
		// From now on, read till EOF
		boost::asio::async_read(*socket, *responseBuf, boost::bind(&Notifier::fetchOnData,
				this, socket, responseBuf, cb, boost::asio::placeholders::error));
	}
	
	void fetchOnData(tcp::socket *socket, boost::asio::streambuf* responseBuf, FetchCallback cb, const boost::system::error_code& err)
	{
		if (err && err != boost::asio::error::eof) {
			if (err == boost::asio::error::operation_aborted) std::cerr << "Fetcher: aborted" << std::endl;
			else std::cerr << "Fetcher: unable to read data from socket" << std::endl;
			
			delete socket;
			delete responseBuf;
			cb(0);
		}
		else if (err == boost::asio::error::eof) {
			delete socket;
			cb(responseBuf); // cb's responsibility to clean up.
		}
		else {
			// Wait for more data
			boost::asio::async_read(*socket, *responseBuf, boost::bind(&Notifier::fetchOnData,
					this, socket, responseBuf, cb, boost::asio::placeholders::error));
		}
	}
	
	// }}}

	void updaterRun(const std::string& _url, FetchCallback gotUpdateCb)
	{
#ifndef UPDATEURL
		if (!_url.size()) return;
		std::string url(_url);
#else
		std::string url(_url.size() ? _url : std::string(UPDATEURL));
#endif
		
		std::cout << "Fetching update from " << url << std::endl;
		
		std::string hostPort, path;
		{
			StringTokenWalker tokens(url, '/');
				// Empty tokens are ignored.

			std::string proto; tokens.next(proto);
			if (proto != "http:") {
				std::cerr << "Updater error: protocol should be 'http'";
				return;
			}
	
			tokens.next(hostPort);
			std::string pathPart;
			while (tokens.tryNext(pathPart)) {
				path.append("/");
				path.append(pathPart);
			}
			if (!path.size()) {
				std::cerr << "Updater error: path seems empty";
				return;
			}
		}
			
		isUpdating = true;
		dataChanged();
			
		std::string host, port;
		{
			StringTokenWalker tokens(hostPort, ':');
			tokens.next(host);
			tokens.tryNext(port, "http");
		}
		
		std::string sigPath(path); sigPath.append(".sig");

		fetch(host, port, sigPath, boost::bind(&Notifier::updaterGotSignature, this, host, port, path, gotUpdateCb, _1));
	}
	
	void updaterGotSignature(std::string& host, std::string& port, std::string& path,
			FetchCallback gotUpdateCb, boost::asio::streambuf* signatureBuf)
	{
		if (signatureBuf) {
			std::string sigS, sigR;
			std::istream data(signatureBuf);
			data >> sigS;
			data >> sigR;
			
			std::cout << "  Got DSA signature: [s=" << sigS << " r=" << sigR << "]" << std::endl;
			
			delete signatureBuf;
			
			fetch(host, port, path, boost::bind(&Notifier::updaterGotBlob, this, sigS, sigR, gotUpdateCb, _1));
			return;
		}
		std::cerr << "Updater: unable to download signature file" << std::endl;
		isUpdating = false;
		dataChanged();
	}
	
	void updaterGotBlob(std::string &sigS, std::string &sigR, FetchCallback gotUpdateCb, boost::asio::streambuf* blobBuf)
	{
		if (blobBuf) {
			int blobLen = blobBuf->size();
			const char* blob = boost::asio::buffer_cast<const char*>(blobBuf->data());

			std::cout << "  Got binary, length=" << blobLen << std::endl;

			int verify = dsa_verify_blob(blob, blobLen, sigS.c_str(), sigR.c_str());

			if (verify == 1) {
				std::cout << "  DSA signature checks out" << std::endl;
				
				gotUpdateCb(blobBuf);
			}
			else std::cerr << "Updater error: verification failed; routine returned " << verify << std::endl;
		}
		else std::cerr << "Updater: unable to download binary" << std::endl;
		
		isUpdating = false;
		dataChanged();
	}
		
	// }}}

};

#endif

