# Nexcess.net Turpentine Extension for Magento
# Copyright (C) 2012  Nexcess.net L.L.C.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

## Nexcessnet_Turpentine Varnish v2 VCL Template

## Custom C Code

C{
    # @source app/code/community/Nexcessnet/Turpentine/misc/uuid.c
    {{custom_c_code}}
}C

## Custom VCL Logic

{{custom_vcl_include}}

## Backends

{{default_backend}}

{{admin_backend}}

## ACLs

{{crawler_acl}}

{{debug_acl}}

## Custom Subroutines
sub remove_cache_headers {
    # remove cache headers so we can set our own
    remove beresp.http.Cache-Control;
    remove beresp.http.Expires;
    remove beresp.http.Pragma;
    remove beresp.http.Cache;
    remove beresp.http.Age;
}

sub remove_double_slashes {
    # remove double slashes from the URL, for higher cache hit rate
    set req.url = regsub(req.url, "(.*)//+(.*)", "\1/\2");
}

sub generate_session {
    # generate a UUID and add `frontend=$UUID` to the Cookie header, or use SID
    # from SID URL param
    if (req.url ~ ".*[&?]SID=([^&]+).*") {
        set req.http.X-Varnish-Faked-Session = regsub(
            req.url, ".*[&?]SID=([^&]+).*", "frontend=\1");
    } else {
        C{
            char uuid_buf [50];
            generate_uuid(uuid_buf);
            VRT_SetHdr(sp, HDR_REQ,
                "\030X-Varnish-Faked-Session:",
                uuid_buf,
                vrt_magic_string_end
            );
        }C
    }
    if (req.http.Cookie) {
        # client sent us cookies, just not a frontend cookie. try not to blow
        # away the extra cookies
        set req.http.Cookie = req.http.X-Varnish-Faked-Session "; " req.http.Cookie;
    } else {
        set req.http.Cookie = req.http.X-Varnish-Faked-Session;
    }
}

sub generate_session_expires {
    # sets X-Varnish-Cookie-Expires to now + esi_private_ttl in format:
    #   Tue, 19-Feb-2013 00:14:27 GMT
    C{
        time_t now = time(NULL);
        struct tm now_tm = *localtime(&now);
        now_tm.tm_sec += {{esi_private_ttl}};
        mktime(&now_tm);
        char date_buf [50];
        strftime(date_buf, sizeof(date_buf)-1, "%a, %d-%b-%Y %H:%M:%S %Z", &now_tm);
        VRT_SetHdr(sp, HDR_RESP,
            "\031X-Varnish-Cookie-Expires:",
            date_buf,
            vrt_magic_string_end
        );
    }C
}

## Varnish Subroutines

sub vcl_recv {
    # this always needs to be done so it's up at the top
    if (req.restarts == 0) {
        if (req.http.X-Forwarded-For) {
            set req.http.X-Forwarded-For =
                req.http.X-Forwarded-For ", " client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }

    # We only deal with GET and HEAD by default
    if (!(req.request ~ "^(GET|HEAD)$")) {
        return (pipe);
    }

    call remove_double_slashes;

    {{normalize_encoding}}
    {{normalize_user_agent}}
    {{normalize_host}}

    # varnish 2.1 doesn't support bare booleans so we have to add these
    # as headers to the req so they've available throught the VCL
    set req.http.X-Opt-Enable-Caching = "{{enable_caching}}";
    set req.http.X-Opt-Force-Static-Caching = "{{force_cache_static}}";
    set req.http.X-Opt-Enable-Get-Excludes = "{{enable_get_excludes}}";

    # we test this here instead of inside the url base regex section
    # so we can disable caching for the entire site if needed
    if (req.http.X-Opt-Enable-Caching != "true" || req.http.Authorization) {
        return (pipe);
    }
    # check if the request is for part of magento
    if (req.url ~ "{{url_base_regex}}") {
        # set this so Turpentine can see the request passed through Varnish
        set req.http.X-Turpentine-Secret-Handshake = "{{secret_handshake}}";
        # use the special admin backend and pipe if it's for the admin section
        if (req.url ~ "{{url_base_regex}}{{admin_frontname}}") {
            set req.backend = admin;
            return (pipe);
        }
        if (req.http.Cookie ~ "\bcurrency=") {
            set req.http.X-Varnish-Currency = regsub(
                req.http.Cookie, ".*\bcurrency=([^;]*).*", "\1");
        }
        if (req.http.Cookie ~ "\bstore=") {
            set req.http.X-Varnish-Store = regsub(
                req.http.Cookie, ".*\bstore=([^;]*).*", "\1");
        }
        # looks like an ESI request, add some extra vars for further processing
        if (req.url ~ "/turpentine/esi/getBlock/") {
            set req.http.X-Varnish-Esi-Method = regsub(
                req.url, ".*/{{esi_method_param}}/(\w+)/.*", "\1");
            set req.http.X-Varnish-Esi-Access = regsub(
                req.url, ".*/{{esi_cache_type_param}}/(\w+)/.*", "\1");

            # throw a forbidden error if debugging is off and a esi block is
            # requested by the user (does not apply to ajax blocks)
            # ** req.esi_level is not available in varnish 2.1
            # if (req.http.X-Varnish-Esi-Method == "esi" && req.esi_level == 0 &&
            #         !({{debug_headers}} || client.ip ~ debug_acl)) {
            #     error 403 "External ESI requests are not allowed";
            # }

            # varnish 2.1 is buggy with compressed esi content
            remove req.http.Accept-Encoding;
        }
        # no frontend cookie was sent to us
        if (req.http.Cookie !~ "frontend=") {
            if (client.ip ~ crawler_acl ||
                    req.http.User-Agent ~ "^(?:{{crawler_user_agent_regex}})$") {
                # it's a crawler, give it a fake cookie
                set req.http.Cookie = "frontend=crawler-session";
            } else {
                # it's a real user, make up a new session for them
                call generate_session;
            }
        }
        if (req.http.X-Opt-Force-Static-Caching == "true" &&
                req.url ~ ".*\.(?:{{static_extensions}})(?=\?|&|$)") {
            # don't need cookies for static assets
            remove req.http.Cookie;
            remove req.http.X-Varnish-Faked-Session;
            return (lookup);
        }
        # this doesn't need a enable_url_excludes because we can be reasonably
        # certain that cron.php at least will always be in it, so it will
        # never be empty
        if (req.url ~ "{{url_base_regex}}(?:{{url_excludes}})") {
            return (pipe);
        }
        if (req.url ~ "\?.*__from_store=") {
            # user switched stores. we pipe this instead of passing below because
            # switching stores doesn't redirect (302), just acts like a link to
            # another page (200) so the Set-Cookie header would be removed
            return (pipe);
        }
        if (req.http.X-Opt-Enable-Get-Excludes == "true" &&
                req.url ~ "(?:[?&](?:{{get_param_excludes}})(?=[&=]|$))") {
            return (pass);
        }
		
		if(req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|gclid|cx|ie|cof|siteurl)=") {
			# Strip out Google related parameters
			set req.url=regsuball(req.url,"&(utm_source|utm_medium|utm_campaign|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)","");
			set req.url=regsuball(req.url,"\?(utm_source|utm_medium|utm_campaign|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)","?");
			set req.url=regsub(req.url,"\?&","?");
			set req.url=regsub(req.url,"\?$","");
		}		
        return (lookup);
    }
    # else it's not part of magento so do default handling (doesn't help
    # things underneath magento but we can't detect that)
}

sub vcl_pipe {
    # since we're not going to do any stuff to the response we pretend the
    # request didn't pass through Varnish
    remove bereq.http.X-Turpentine-Secret-Handshake;
    set bereq.http.Connection = "close";
}

# sub vcl_pass {
#     return (pass);
# }

sub vcl_hash {
    set req.hash += req.url;
    if (req.http.Host) {
        set req.hash += req.http.Host;
    } else {
        set req.hash += server.ip;
    }
    set req.hash += req.http.Ssl-Offloaded;
    if (req.http.X-Normalized-User-Agent) {
        set req.hash += req.http.X-Normalized-User-Agent;
    }
    if (req.http.Accept-Encoding) {
        # make sure we give back the right encoding
        set req.hash += req.http.Accept-Encoding;
    }
    # make sure data is for the right store and currency based on the *store*
    # and *currency* cookies
    set req.hash += "s=" req.http.X-Varnish-Store "&c=" req.http.X-Varnish-Currency;
    if (req.http.X-Varnish-Esi-Access == "private" &&
            req.http.Cookie ~ "frontend=") {
        set req.hash += regsub(req.http.Cookie, "^.*?frontend=([^;]*);*.*$", "\1");
        {{advanced_session_validation}}
    }
    return (hash);
}

# This doesn't work in Varnish 2.1
# sub vcl_hit {
#     if (obj.hits > 0) {
#         set obj.ttl = obj.ttl + {{lru_factor}}s;
#     }
# }

# sub vcl_miss {
#     return (fetch);
# }

sub vcl_fetch {
    # set the grace period
    set req.grace = {{grace_period}}s;

    # if it's part of magento...
    if (req.url ~ "{{url_base_regex}}") {
        # we handle the Vary stuff ourselves for now, we'll want to actually
        # use this eventually for compatibility with downstream proxies
        # TODO: only remove the User-Agent field from this if it exists
        remove beresp.http.Vary;

        if (beresp.status != 200 && beresp.status != 404) {
            # don't cache if it's not a 200 or 404
            set beresp.ttl = {{grace_period}}s;
            return (pass);
        } else {
            # if Magento sent us a Set-Cookie header, we'll put it somewhere
            # else for now
            if (beresp.http.Set-Cookie) {
                set beresp.http.X-Varnish-Set-Cookie = beresp.http.Set-Cookie;
                remove beresp.http.Set-Cookie;
            }
            # we'll set our own cache headers if we need them
            call remove_cache_headers;

            if (beresp.http.X-Turpentine-Esi == "1") {
                esi;
            }
            if (beresp.http.X-Turpentine-Cache == "0") {
                set beresp.cacheable = false;
                set beresp.ttl = {{grace_period}}s;
                return (pass);
            } else {
                set beresp.cacheable = true;
                if (req.http.X-Opt-Force-Static-Caching == "true" &&
                        bereq.url ~ ".*\.(?:{{static_extensions}})(?=\?|&|$)") {
                    # it's a static asset
                    set beresp.ttl = {{static_ttl}}s;
                    set beresp.http.Cache-Control = "max-age={{static_ttl}}";
                } else if (req.http.X-Varnish-Esi-Method) {
                    # it's a ESI request
                    # TODO: make the TTLs properly dynamic
                    if (req.http.X-Varnish-Esi-Access == "private") {
                        if (req.http.Cookie ~ "frontend=") {
                            # set this header so we can ban by session from Turpentine
                            set beresp.http.X-Varnish-Session = regsub(req.http.Cookie,
                                "^.*?frontend=([^;]*);*.*$", "\1");
                        }
                        if (req.http.X-Varnish-Esi-Method == "ajax") {
                            set beresp.ttl = {{grace_period}}s;
                            return (pass);
                        } else {
                            set beresp.ttl = {{esi_private_ttl}}s;
                        }
                    } else {
                        if (req.http.X-Varnish-Esi-Method == "ajax") {
                            set beresp.http.Cache-Control =
                                "max-age={{esi_public_ttl}}";
                        }
                        set beresp.ttl = {{esi_public_ttl}}s;
                    }
                } else {
                    {{url_ttls}}
                }
            }
        }
        # we've done what we need to, send to the client
        return (deliver);
    }
    # else it's not part of Magento so use the default Varnish handling
}

sub vcl_deliver {
    if (req.http.X-Varnish-Faked-Session) {
        # need to set the set-cookie header since we just made it out of thin air
        call generate_session_expires;
        set resp.http.Set-Cookie = req.http.X-Varnish-Faked-Session "; expires="
            resp.http.X-Varnish-Cookie-Expires "; path="
            regsub(regsub(req.url, "{{url_base_regex}}.*", "\1"), "^(.+)/$", "\1");
        if (req.http.Host) {
            set resp.http.Set-Cookie = resp.http.Set-Cookie
                "; domain=" regsub(req.http.Host, ":\d+$", "");
        }
        set resp.http.Set-Cookie = resp.http.Set-Cookie "; HttpOnly";
        remove resp.http.X-Varnish-Cookie-Expires;
    }
    set resp.http.X-Opt-Debug-Headers = "{{debug_headers}}";
    if (resp.http.X-Opt-Debug-Headers == "true" || client.ip ~ debug_acl ) {
        # debugging is on, give some extra info
        set resp.http.X-Varnish-Hits = obj.hits;
        set resp.http.X-Varnish-Esi-Method = req.http.X-Varnish-Esi-Method;
        set resp.http.X-Varnish-Esi-Access = req.http.X-Varnish-Esi-Access;
        set resp.http.X-Varnish-Currency = req.http.X-Varnish-Currency;
        set resp.http.X-Varnish-Store = req.http.X-Varnish-Store;
    } else {
        # remove Varnish fingerprints
        remove resp.http.X-Varnish;
        remove resp.http.Via;
        remove resp.http.X-Powered-By;
        remove resp.http.Server;
        remove resp.http.X-Turpentine-Cache;
        remove resp.http.X-Turpentine-Esi;
        remove resp.http.X-Turpentine-Flush-Events;
        remove resp.http.X-Turpentine-Block;
        remove resp.http.X-Varnish-Session;
        # this header indicates the session that originally generated a cached
        # page. it *must* not be sent to a client in production with lax
        # session validation or that session can be hijacked
        remove resp.http.X-Varnish-Set-Cookie;
    }
    remove resp.http.X-Opt-Debug-Headers;
}
