#include <iostream>
#include <unistd.h>
#include <sys/stat.h>
//#include <mutex>
#include <thread>
#include <atomic>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <curl/curl.h>

#include "handler/settings.h"
#include "utils/base64/base64.h"
#include "utils/defer.h"
#include "utils/file_extra.h"
#include "utils/lock.h"
#include "utils/logger.h"
#include "utils/urlencode.h"
#include "version.h"
#include "webget.h"
#include "server/socket.h"

#ifdef _WIN32
#ifndef _stat
#define _stat stat
#endif // _stat
#endif // _WIN32

/*
using guarded_mutex = std::lock_guard<std::mutex>;
std::mutex cache_rw_lock;
*/

RWLock cache_rw_lock;

//std::string user_agent_str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36";
static auto user_agent_str = "subconverter/" VERSION " cURL/" LIBCURL_VERSION;

namespace
{
struct HttpTarget
{
    std::string scheme;
    std::string host;
    std::string port;
};

static bool parse_http_target(const std::string &url, HttpTarget &target)
{
    const auto scheme_end = url.find("://");
    if(scheme_end == std::string::npos)
        return false;
    target.scheme = toLower(url.substr(0, scheme_end));
    if(target.scheme != "http" && target.scheme != "https")
        return false;
    const auto authority_start = scheme_end + 3;
    const auto authority_end = url.find_first_of("/?#", authority_start);
    const auto authority = url.substr(authority_start, authority_end == std::string::npos ? std::string::npos : authority_end - authority_start);
    if(authority.empty() || authority.find('@') != std::string::npos)
        return false;

    if(authority.front() == '[')
    {
        const auto close = authority.find(']');
        if(close == std::string::npos || close == 1)
            return false;
        target.host = authority.substr(1, close - 1);
        if(close + 1 < authority.size())
        {
            if(authority[close + 1] != ':')
                return false;
            target.port = authority.substr(close + 2);
        }
    }
    else
    {
        const auto colon = authority.rfind(':');
        if(colon != std::string::npos)
        {
            if(authority.find(':') != colon)
                return false;
            target.host = authority.substr(0, colon);
            target.port = authority.substr(colon + 1);
        }
        else
            target.host = authority;
    }
    if(target.host.empty())
        return false;
    if(target.port.empty())
        target.port = target.scheme == "https" ? "443" : "80";
    char *end = nullptr;
    const auto port = std::strtol(target.port.c_str(), &end, 10);
    return end != target.port.c_str() && *end == '\0' && port > 0 && port <= 65535;
}

static bool forbidden_ipv4(const in_addr &addr)
{
    const uint32_t value = ntohl(addr.s_addr);
    const auto in_range = [value](uint32_t first, uint32_t last) { return value >= first && value <= last; };
    return in_range(0x00000000U, 0x00FFFFFFU) ||       // unspecified/current network
           in_range(0x0A000000U, 0x0AFFFFFFU) ||       // RFC1918
           in_range(0x64400000U, 0x647FFFFFU) ||       // carrier-grade NAT
           in_range(0x7F000000U, 0x7FFFFFFFU) ||       // loopback
           in_range(0xA9FE0000U, 0xA9FEFFFFU) ||       // link-local / cloud metadata
           in_range(0xAC100000U, 0xAC1FFFFFU) ||       // RFC1918
           in_range(0xC0000000U, 0xC00000FFU) ||       // IETF protocol assignments
           in_range(0xC0000200U, 0xC00002FFU) ||       // TEST-NET-1
           in_range(0xC0A80000U, 0xC0A8FFFFU) ||       // RFC1918
           in_range(0xCB007100U, 0xCB0071FFU) ||       // TEST-NET-3
           in_range(0xC6336400U, 0xC63364FFU) ||       // benchmark
           value >= 0xE0000000U;                       // multicast/reserved
}

static bool forbidden_ipv6(const in6_addr &addr)
{
    const auto *b = reinterpret_cast<const unsigned char *>(&addr);
    if((b[0] == 0 && std::all_of(b + 1, b + 16, [](unsigned char x) { return x == 0; })) ||
       (b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 0 && b[4] == 0 && b[5] == 0 &&
        b[6] == 0 && b[7] == 0 && b[8] == 0 && b[9] == 0 && b[10] == 0 && b[11] == 0 &&
        b[12] == 0 && b[13] == 0 && b[14] == 0 && b[15] == 1))
        return true;
    if((b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || (b[0] & 0xFF) == 0xFF)
        return true; // ULA, link-local, multicast
    if(std::all_of(b, b + 10, [](unsigned char x) { return x == 0; }) && b[10] == 0xFF && b[11] == 0xFF)
    {
        in_addr mapped{};
        std::memcpy(&mapped.s_addr, b + 12, sizeof(mapped.s_addr));
        return forbidden_ipv4(mapped);
    }
    return false;
}

static bool resolve_safe_target(const std::string &url, std::vector<std::string> &resolve_entries)
{
    HttpTarget target;
    if(!parse_http_target(url, target))
        return false;
    addrinfo hints{};
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    addrinfo *result = nullptr;
    if(getaddrinfo(target.host.c_str(), target.port.c_str(), &hints, &result) != 0 || result == nullptr)
        return false;
    bool safe = true;
    for(auto *cur = result; cur; cur = cur->ai_next)
    {
        char address[INET6_ADDRSTRLEN]{};
        if(cur->ai_family == AF_INET)
        {
            const auto *a = reinterpret_cast<const sockaddr_in *>(cur->ai_addr);
            safe = safe && !forbidden_ipv4(a->sin_addr);
            if(inet_ntop(AF_INET, &a->sin_addr, address, sizeof(address)))
                resolve_entries.emplace_back(target.host + ":" + target.port + ":" + address);
        }
        else if(cur->ai_family == AF_INET6)
        {
            const auto *a = reinterpret_cast<const sockaddr_in6 *>(cur->ai_addr);
            safe = safe && !forbidden_ipv6(a->sin6_addr);
            if(inet_ntop(AF_INET6, &a->sin6_addr, address, sizeof(address)))
                resolve_entries.emplace_back(target.host + ":" + target.port + ":[" + address + "]");
        }
    }
    freeaddrinfo(result);
    return safe && !resolve_entries.empty();
}

static bool is_safe_forward_header(const std::string &name)
{
    const auto lower = toLower(name);
    return lower == "user-agent" || lower == "accept" || lower == "accept-language" ||
           lower == "referer" || lower == "x-requested-with" || lower == "content-type";
}

static std::string redirect_target(const std::string &current, const std::string &location)
{
    if(location.empty())
        return {};
    if(startsWith(toLower(location), "http://") || startsWith(toLower(location), "https://"))
        return location;
    HttpTarget current_target;
    if(!parse_http_target(current, current_target))
        return {};
    const auto authority_end = current.find_first_of("/?#", current.find("://") + 3);
    const auto origin = current.substr(0, authority_end == std::string::npos ? current.size() : authority_end);
    if(startsWith(location, "//"))
        return current_target.scheme + ":" + location;
    if(location.front() == '/')
        return origin + location;
    const auto path_end = current.find_last_of('/');
    return current.substr(0, path_end == std::string::npos ? current.size() : path_end + 1) + location;
}

static std::string location_from_headers(const std::string &headers)
{
    auto lines = split(headers, "\r\n");
    for(const auto &line : lines)
    {
        const auto colon = line.find(':');
        if(colon == std::string::npos || toLower(trim(line.substr(0, colon))) != "location")
            continue;
        return trim(line.substr(colon + 1));
    }
    return {};
}
}

struct curl_progress_data
{
    long size_limit = 0L;
};

static inline void curl_init()
{
    static bool init = false;
    if(!init)
    {
        curl_global_init(CURL_GLOBAL_ALL);
        init = true;
    }
}

static int writer(char *data, size_t size, size_t nmemb, std::string *writerData)
{
    if(writerData == nullptr)
        return 0;

    writerData->append(data, size*nmemb);

    return static_cast<int>(size * nmemb);
}

static int dummy_writer(char *, size_t size, size_t nmemb, void *)
{
    /// dummy writer, do not save anything
    return static_cast<int>(size * nmemb);
}

//static int size_checker(void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow)
static int size_checker(void *clientp, curl_off_t, curl_off_t dlnow, curl_off_t, curl_off_t)
{
    if(clientp)
    {
        auto *data = reinterpret_cast<curl_progress_data*>(clientp);
        if(data->size_limit)
        {
            if(dlnow > data->size_limit)
                return 1;
        }
    }
    return 0;
}

static int logger(CURL *handle, curl_infotype type, char *data, size_t size, void *userptr)
{
    (void)handle;
    (void)userptr;
    std::string prefix;
    switch(type)
    {
    case CURLINFO_TEXT:
        prefix = "CURL_INFO: ";
        break;
    case CURLINFO_HEADER_IN:
        prefix = "CURL_HEADER: < ";
        break;
    case CURLINFO_HEADER_OUT:
        prefix = "CURL_HEADER: > ";
        break;
    case CURLINFO_DATA_IN:
    case CURLINFO_DATA_OUT:
    default:
        return 0;
    }
    std::string content(data, size);
    if(content.find("\r\n") != std::string::npos)
    {
        string_array lines = split(content, "\r\n");
        for(auto &x : lines)
        {
            std::string log_content = prefix;
            log_content += x;
            writeLog(0, log_content, LOG_LEVEL_VERBOSE);
        }
    }
    else
    {
        std::string log_content = prefix;
        log_content += trimWhitespace(content);
        writeLog(0, log_content, LOG_LEVEL_VERBOSE);
    }
    return 0;
}

static inline void curl_set_common_options(CURL *curl_handle, const char *url, curl_progress_data *data)
{
    curl_easy_setopt(curl_handle, CURLOPT_URL, url);
    curl_easy_setopt(curl_handle, CURLOPT_VERBOSE, global.logLevel == LOG_LEVEL_VERBOSE ? 1L : 0L);
    curl_easy_setopt(curl_handle, CURLOPT_DEBUGFUNCTION, logger);
    curl_easy_setopt(curl_handle, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl_handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl_handle, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl_handle, CURLOPT_MAXREDIRS, 20L);
    curl_easy_setopt(curl_handle, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl_handle, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl_handle, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
    curl_easy_setopt(curl_handle, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
    curl_easy_setopt(curl_handle, CURLOPT_TIMEOUT, 15L);
    if(data)
    {
        if(data->size_limit)
            curl_easy_setopt(curl_handle, CURLOPT_MAXFILESIZE, data->size_limit);
        curl_easy_setopt(curl_handle, CURLOPT_XFERINFOFUNCTION, size_checker);
        curl_easy_setopt(curl_handle, CURLOPT_XFERINFODATA, data);
    }
}

//static std::string curlGet(const std::string &url, const std::string &proxy, std::string &response_headers, CURLcode &return_code, const string_map &request_headers)
static int curlGet(const FetchArgument &argument, FetchResult &result)
{
    CURL *curl_handle;
    std::string *data = result.content, new_url = argument.url;
    curl_slist *header_list = nullptr;
    curl_slist *resolve_list = nullptr;
    bool cors_request = false;
    defer(curl_slist_free_all(header_list);)
    defer(curl_slist_free_all(resolve_list);)
    long retVal;

    curl_init();

    curl_handle = curl_easy_init();
    if(!argument.proxy.empty())
    {
        if(startsWith(argument.proxy, "cors:"))
        {
            cors_request = true;
            new_url = argument.proxy.substr(5) + argument.url;
        }
        else
            curl_easy_setopt(curl_handle, CURLOPT_PROXY, argument.proxy.data());
    }
    curl_progress_data limit;
    limit.size_limit = global.maxAllowedDownloadSize;
    curl_set_common_options(curl_handle, new_url.data(), &limit);

    auto rebuild_headers = [&](const std::string &request_url)
    {
        curl_slist_free_all(header_list);
        header_list = nullptr;
        if(cors_request)
            header_list = curl_slist_append(header_list, "X-Requested-With: subconverter " VERSION);
        header_list = curl_slist_append(header_list, "Content-Type: application/json;charset=utf-8");

        HttpTarget target;
        const bool trusted_github_target = parse_http_target(request_url, target) &&
            target.scheme == "https" && toLower(target.host) == "api.github.com";
        bool has_user_agent = false;
        if(argument.request_headers)
        {
            for(auto &x : *argument.request_headers)
            {
                const auto lower_name = toLower(x.first);
                const bool trusted_github_auth = argument.allow_authorization &&
                    lower_name == "authorization" && trusted_github_target;
                if(lower_name == "cookie" || (!is_safe_forward_header(x.first) && !trusted_github_auth))
                    continue;
                auto header = x.first + ": " + x.second;
                header_list = curl_slist_append(header_list, header.data());
                has_user_agent = has_user_agent || lower_name == "user-agent";
            }
        }
        if(!has_user_agent)
            curl_easy_setopt(curl_handle, CURLOPT_USERAGENT, user_agent_str);
        header_list = curl_slist_append(header_list, "SubConverter-Request: 1");
        header_list = curl_slist_append(header_list, "SubConverter-Version: " VERSION);
        curl_easy_setopt(curl_handle, CURLOPT_HTTPHEADER, header_list);
    };

    if(result.content)
    {
        curl_easy_setopt(curl_handle, CURLOPT_WRITEFUNCTION, writer);
        curl_easy_setopt(curl_handle, CURLOPT_WRITEDATA, result.content);
    }
    else
        curl_easy_setopt(curl_handle, CURLOPT_WRITEFUNCTION, dummy_writer);
    if(result.response_headers)
    {
        curl_easy_setopt(curl_handle, CURLOPT_HEADERFUNCTION, writer);
        curl_easy_setopt(curl_handle, CURLOPT_HEADERDATA, result.response_headers);
    }
    else
        curl_easy_setopt(curl_handle, CURLOPT_HEADERFUNCTION, dummy_writer);

    switch(argument.method)
    {
    case HTTP_POST:
        curl_easy_setopt(curl_handle, CURLOPT_POST, 1L);
        if(argument.post_data)
        {
            curl_easy_setopt(curl_handle, CURLOPT_POSTFIELDS, argument.post_data->data());
            curl_easy_setopt(curl_handle, CURLOPT_POSTFIELDSIZE, argument.post_data->size());
        }
        break;
    case HTTP_PATCH:
        curl_easy_setopt(curl_handle, CURLOPT_CUSTOMREQUEST, "PATCH");
        if(argument.post_data)
        {
            curl_easy_setopt(curl_handle, CURLOPT_POSTFIELDS, argument.post_data->data());
            curl_easy_setopt(curl_handle, CURLOPT_POSTFIELDSIZE, argument.post_data->size());
        }
        break;
    case HTTP_HEAD:
        curl_easy_setopt(curl_handle, CURLOPT_NOBODY, 1L);
        break;
    case HTTP_GET:
        break;
    }

    unsigned int fail_count = 0, max_fails = 1, redirect_count = 0;
    while(true)
    {
        std::vector<std::string> resolve_entries;
        if(!resolve_safe_target(new_url, resolve_entries))
        {
            retVal = CURLE_COULDNT_CONNECT;
            break;
        }
        curl_slist_free_all(resolve_list);
        resolve_list = nullptr;
        for(const auto &entry : resolve_entries)
            resolve_list = curl_slist_append(resolve_list, entry.c_str());
        curl_easy_setopt(curl_handle, CURLOPT_RESOLVE, resolve_list);
        curl_easy_setopt(curl_handle, CURLOPT_URL, new_url.c_str());
        rebuild_headers(new_url);
        if(result.content)
            result.content->clear();
        if(result.response_headers)
            result.response_headers->clear();
        retVal = curl_easy_perform(curl_handle);
        if(retVal == CURLE_OK || max_fails <= fail_count || global.APIMode)
        {
            long code = 0;
            curl_easy_getinfo(curl_handle, CURLINFO_HTTP_CODE, &code);
            if(code >= 300 && code < 400 && redirect_count < 20)
            {
                char *effective_redirect = nullptr;
                curl_easy_getinfo(curl_handle, CURLINFO_REDIRECT_URL, &effective_redirect);
                const auto location = effective_redirect ? std::string(effective_redirect) : location_from_headers(result.response_headers ? *result.response_headers : "");
                const auto next_url = redirect_target(new_url, location);
                if(!next_url.empty())
                {
                    new_url = next_url;
                    redirect_count++;
                    continue;
                }
            }
            break;
        }
        else
            fail_count++;
    }

    long code = 0;
    curl_easy_getinfo(curl_handle, CURLINFO_HTTP_CODE, &code);
    *result.status_code = code;

    if(result.cookies)
    {
        curl_slist *cookies = nullptr;
        curl_easy_getinfo(curl_handle, CURLINFO_COOKIELIST, &cookies);
        if(cookies)
        {
            auto each = cookies;
            while(each)
            {
                result.cookies->append(each->data);
                *result.cookies += "\r\n";
                each = each->next;
            }
        }
        curl_slist_free_all(cookies);
    }

    curl_easy_cleanup(curl_handle);

    if(data && !argument.keep_resp_on_fail)
    {
        if(retVal != CURLE_OK || *result.status_code != 200)
            data->clear();
        data->shrink_to_fit();
    }

    return *result.status_code;
}

// data:[<mediatype>][;base64],<data>
static std::string dataGet(const std::string &url)
{
    if (!startsWith(url, "data:"))
        return "";
    std::string::size_type comma = url.find(',');
    if (comma == std::string::npos || comma == url.size() - 1)
        return "";

    std::string data = urlDecode(url.substr(comma + 1));
    if (endsWith(url.substr(0, comma), ";base64")) {
        return urlSafeBase64Decode(data);
    } else {
        return data;
    }
}

std::string buildSocks5ProxyString(const std::string &addr, int port, const std::string &username, const std::string &password)
{
    std::string authstr = username.size() && password.size() ? username + ":" + password + "@" : "";
    std::string proxystr = "socks5://" + authstr + addr + ":" + std::to_string(port);
    return proxystr;
}

std::string webGet(const std::string &url, const std::string &proxy, unsigned int cache_ttl, std::string *response_headers, string_icase_map *request_headers)
{
    int return_code = 0;
    std::string content;

    FetchArgument argument {HTTP_GET, url, proxy, nullptr, request_headers, nullptr, cache_ttl};
    FetchResult fetch_res {&return_code, &content, response_headers, nullptr};

    if (startsWith(url, "data:"))
        return dataGet(url);
    // cache system
    if(cache_ttl > 0)
    {
        md("cache");
        const std::string url_md5 = getMD5(url);
        const std::string path = "cache/" + url_md5, path_header = path + "_header";
        struct stat result {};
        if(stat(path.data(), &result) == 0) // cache exist
        {
            time_t mtime = result.st_mtime, now = time(nullptr); // get cache modified time and current time
            if(difftime(now, mtime) <= cache_ttl) // within TTL
            {
                writeLog(0, "CACHE HIT: '" + url + "', using local cache.");
                //guarded_mutex guard(cache_rw_lock);
                cache_rw_lock.readLock();
                defer(cache_rw_lock.readUnlock();)
                if(response_headers)
                    *response_headers = fileGet(path_header, true);
                return fileGet(path, true);
            }
            writeLog(0, "CACHE MISS: '" + url + "', TTL timeout, creating new cache."); // out of TTL
        }
        else
            writeLog(0, "CACHE NOT EXIST: '" + url + "', creating new cache.");
        //content = curlGet(url, proxy, response_headers, return_code); // try to fetch data
        curlGet(argument, fetch_res);
        if(return_code == 200) // success, save new cache
        {
            //guarded_mutex guard(cache_rw_lock);
            cache_rw_lock.writeLock();
            defer(cache_rw_lock.writeUnlock();)
            fileWrite(path, content, true);
            if(response_headers)
                fileWrite(path_header, *response_headers, true);
        }
        else
        {
            if(fileExist(path) && global.serveCacheOnFetchFail) // failed, check if cache exist
            {
                writeLog(0, "Fetch failed. Serving cached content."); // cache exist, serving cache
                //guarded_mutex guard(cache_rw_lock);
                cache_rw_lock.readLock();
                defer(cache_rw_lock.readUnlock();)
                content = fileGet(path, true);
                if(response_headers)
                    *response_headers = fileGet(path_header, true);
            }
            else
                writeLog(0, "Fetch failed. No local cache available."); // cache not exist or not allow to serve cache, serving nothing
        }
        return content;
    }
    //return curlGet(url, proxy, response_headers, return_code);
    curlGet(argument, fetch_res);
    return content;
}

void flushCache()
{
    //guarded_mutex guard(cache_rw_lock);
    cache_rw_lock.writeLock();
    defer(cache_rw_lock.writeUnlock();)
    operateFiles("cache", [](const std::string &file){ remove(("cache/" + file).data()); return 0; });
}

int webPost(const std::string &url, const std::string &data, const std::string &proxy, const string_icase_map &request_headers, std::string *retData, bool allow_authorization)
{
    //return curlPost(url, data, proxy, request_headers, retData);
    int return_code = 0;
    FetchArgument argument {HTTP_POST, url, proxy, &data, &request_headers, nullptr, 0, true, allow_authorization};
    FetchResult fetch_res {&return_code, retData, nullptr, nullptr};
    return webGet(argument, fetch_res);
}

int webPatch(const std::string &url, const std::string &data, const std::string &proxy, const string_icase_map &request_headers, std::string *retData, bool allow_authorization)
{
    //return curlPatch(url, data, proxy, request_headers, retData);
    int return_code = 0;
    FetchArgument argument {HTTP_PATCH, url, proxy, &data, &request_headers, nullptr, 0, true, allow_authorization};
    FetchResult fetch_res {&return_code, retData, nullptr, nullptr};
    return webGet(argument, fetch_res);
}

int webHead(const std::string &url, const std::string &proxy, const string_icase_map &request_headers, std::string &response_headers)
{
    //return curlHead(url, proxy, request_headers, response_headers);
    int return_code = 0;
    FetchArgument argument {HTTP_HEAD, url, proxy, nullptr, &request_headers, nullptr, 0};
    FetchResult fetch_res {&return_code, nullptr, &response_headers, nullptr};
    return webGet(argument, fetch_res);
}

string_array headers_map_to_array(const string_map &headers)
{
    string_array result;
    for(auto &kv : headers)
        result.push_back(kv.first + ": " + kv.second);
    return result;
}

int webGet(const FetchArgument& argument, FetchResult &result)
{
    return curlGet(argument, result);
}
