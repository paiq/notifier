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

#define USERAGENT SITENAME " Notifier/1.2.0 (Linux)"

#include <unistd.h>
#include <string>
#include <list>

#include <signal.h>

#include <boost/asio.hpp>
#include <boost/bind.hpp>

#include "Notifier.h"

class ConsoleNotifier : public Notifier
{
public:
	ConsoleNotifier(boost::asio::io_service& ioService_) : Notifier(ioService_) {}

	virtual void notify(const std::string& title, const std::string& text, const std::string& url, bool sticky, bool prio)
	{
		std::cout	<< "Notify:  " << title << std::endl
					<< "         " << text << std::endl
					<< "        (" << url << ")" << std::endl;
	}

	virtual void openUrl(const std::string& url)
	{
		std::cout	<< "URL:     " << url << std::endl;
	}

	/*virtual void dataChanged()
	{
		std::cout 	<< "new data:  cookie=" << cookie << std::endl
					<< "           userId=" << userId << std::endl
					<< "       unreadMsgs=" << unreadMsgs << std::endl
					<< "        maleUsers=" << maleUsers << std::endl
					<< "      femaleUsers=" << femaleUsers << std::endl
					<< "      onlineUsers=" << onlineUsers << std::endl;
	}*/

	virtual void tooltip(const std::list<std::string>& items) {
		for (std::list<std::string>::const_iterator i = items.begin(); i != items.end(); i++)
			std::cout << (i == items.begin() ? "Tooltip:  " : "          ") << (*i) << std::endl;
	}

};

boost::asio::io_service runloop;
ConsoleNotifier notifier(runloop);

void handle_sigint(int sig)
{
	std::cout << "Received sigint" << std::endl;
	runloop.post(boost::bind(&ConsoleNotifier::quit, &notifier));
}

int main()
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = &handle_sigint;
	sigaction(SIGINT, &sa, NULL);

	runloop.post(boost::bind(&Notifier::setEnabled, &notifier, true, false));
	runloop.run();
	
	std::cout << "ConsoleNotifier runloop complete" << std::endl;
}

