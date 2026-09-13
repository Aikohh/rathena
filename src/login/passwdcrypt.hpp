// Copyright (c) rAthena Dev Teams - Licensed under GNU GPL
// For more information, see LICENCE in the main folder

#ifndef PASSWDCRYPT_HPP
#define PASSWDCRYPT_HPP

#include <string>

/**
 * Account password hashing with Argon2id.
 *
 * Argon2id won the Password Hashing Competition and is the current OWASP
 * first choice. Unlike bcrypt it is explicitly memory-hard: the cost of a
 * guess is bounded by memory bandwidth rather than raw compute, which is what
 * blunts GPU and ASIC attacks.
 *
 * Stored form is the standard PHC string, so the parameters travel with each
 * hash and can be raised later without invalidating existing rows:
 *
 *   $argon2id$v=19$m=19456,t=2,p=1$<salt>$<digest>
 *
 * Parameters follow the OWASP baseline: 19 MiB, 2 iterations, 1 lane.
 * Encoded length at those settings is 98 characters (argon2_encodedlen).
 */

/// OWASP baseline. Raising these only affects newly written hashes.
#define PASSWD_ARGON2_MEMORY 19456 ///< KiB
#define PASSWD_ARGON2_TIME   2     ///< iterations
#define PASSWD_ARGON2_LANES  1     ///< parallelism
#define PASSWD_ARGON2_SALT   16    ///< bytes
#define PASSWD_ARGON2_HASH   32    ///< bytes

/// Longest stored form. Keep `login`.`user_pass` at least this wide.
#define PASSWD_ARGON2_ENCODED 98

/// Prefix every Argon2id hash carries.
#define PASSWD_ARGON2_PREFIX "$argon2id$"

/**
 * Hash a cleartext password.
 * @return the PHC string, or an empty string on failure (never throws).
 */
std::string passwd_hash( const char* plain );

/**
 * Verify a cleartext password against a stored PHC string.
 * Returns false for a malformed or empty hash rather than reporting a match.
 */
bool passwd_verify( const char* plain, const char* encoded );

/// Does this stored value look like an Argon2id PHC string?
bool passwd_is_argon2( const char* stored );

/// Does this stored value look like a legacy 32-character MD5 hex digest?
bool passwd_is_md5( const char* stored );

#endif /* PASSWDCRYPT_HPP */
