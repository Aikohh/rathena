// Copyright (c) rAthena Dev Teams - Licensed under GNU GPL
// For more information, see LICENCE in the main folder

#ifndef ACCOUNT_HPP
#define ACCOUNT_HPP

#include <common/cbasetypes.hpp>
#include <common/mmo.hpp> // ACCOUNT_REG2_NUM, WEB_AUTH_TOKEN_LENGTH
#include <config/core.hpp>

typedef struct AccountDB AccountDB;
typedef struct AccountDBIterator AccountDBIterator;


// standard engines
AccountDB* account_db_sql(void);

/// How `login`.`user_pass` is stored for an account.
enum e_passwd_type : uint8 {
	PASSWD_TYPE_LEGACY = 0,       ///< plaintext, or a 32-char MD5 hash
	PASSWD_TYPE_ARGON2 = 1,       ///< argon2id( password )
	PASSWD_TYPE_ARGON2_MD5 = 2,   ///< argon2id( MD5( password ) ), migrated MD5 rows
	PASSWD_TYPE_ARGON2_PEPPER = 3,///< argon2id( MD5( pepper + password ) ), see password_pepper

	/// OR-ed into the type above when password_hash_pepper was set at the time
	/// the row was written: the input was HMAC-SHA256(pepper, input) first.
	/// A flag rather than a fourth value, so it composes with all three forms
	/// and rows written with and without a pepper can coexist.
	PASSWD_FLAG_PEPPERED = 0x10,

	/// The next login SETS this account's password instead of checking it.
	/// For a player who has forgotten theirs: the operator raises the flag,
	/// the player types the password they want, and it is stored and the flag
	/// cleared in the same step. The operator never learns the password and
	/// there is no temporary one to leak or forget to change.
	///
	/// While it is raised the account has no password, so anyone who knows the
	/// name can claim it. Raise it when the player is ready, not in advance.
	PASSWD_FLAG_ENROLL = 0x20,
};

/// The storage form, with the pepper flag masked off.
#define PASSWD_TYPE_BASE(t) ((t) & 0x0F)
/// Was this row written with the server-side hash pepper applied?
#define PASSWD_IS_PEPPERED(t) (((t) & PASSWD_FLAG_PEPPERED) != 0)
/// Is this account waiting for its owner to choose a password?
#define PASSWD_IS_ENROLLING(t) (((t) & PASSWD_FLAG_ENROLL) != 0)

struct mmo_account {
	uint32 account_id;
	char userid[NAME_LENGTH];
	char pass[98+1];        // 23+1 plaintext, 32+1 md5, 98+1 argon2id (PASSWD_ARGON2_ENCODED)
	char sex;               // gender (M/F/S)
	char email[40];         // e-mail (by default: a@a.com)
	uint32 group_id;        // player group id
	uint8 char_slots;       // this accounts maximum character slots (maximum is limited to MAX_CHARS define in char server)
	uint32 state;           // packet 0x006a value + 1 (0: compte OK)
	time_t unban_time;      // (timestamp): ban time limit of the account (0 = no ban)
	time_t expiration_time; // (timestamp): validity limit of the account (0 = unlimited)
	uint32 logincount;      // number of successful auth attempts
	char lastlogin[24];     // date+time of last successful login
	char last_ip[16];       // save of last IP of connection
	char birthdate[10+1];   // assigned birth date (format: YYYY-MM-DD)
	char pincode[PINCODE_LENGTH+1];		// pincode system
	time_t pincode_change;	// (timestamp): last time of pincode change
	char web_auth_token[WEB_AUTH_TOKEN_LENGTH]; // web authentication token (randomized on each login)
	uint8 passwd_type; // see e_passwd_type
#ifdef VIP_ENABLE
	int32 old_group;
	time_t vip_time;
#endif
};


struct AccountDBIterator {
	/// Destroys this iterator, releasing all allocated memory (including itself).
	///
	/// @param self Iterator
	void (*destroy)(AccountDBIterator* self);

	/// Fetches the next account in the database.
	/// Fills acc with the account data.
	/// @param self Iterator
	/// @param acc Account data
	/// @return true if successful
	bool (*next)(AccountDBIterator* self, struct mmo_account* acc);
};


struct AccountDB {
	/// Initializes this database, making it ready for use.
	/// Call this after setting the properties.
	///
	/// @param self Database
	/// @return true if successful
	bool (*init)(AccountDB* self);

	/// Destroys this database, releasing all allocated memory (including itself).
	///
	/// @param self Database
	void (*destroy)(AccountDB* self);

	/// Gets a property from this database.
	/// These read-only properties must be implemented:
	///
	/// @param self Database
	/// @param key Property name
	/// @param buf Buffer for the value
	/// @param buflen Buffer length
	/// @return true if successful
	bool (*get_property)(AccountDB* self, const char* key, char* buf, size_t buflen);

	/// Sets a property in this database.
	///
	/// @param self Database
	/// @param key Property name
	/// @param value Property value
	/// @return true if successful
	bool (*set_property)(AccountDB* self, const char* key, const char* value);

	/// Creates a new account in this database.
	/// If acc->account_id is not -1, the provided value will be used.
	/// Otherwise the account_id will be auto-generated and written to acc->account_id.
	///
	/// @param self Database
	/// @param acc Account data
	/// @return true if successful
	bool (*create)(AccountDB* self, struct mmo_account* acc);

	/// Removes an account from this database.
	///
	/// @param self Database
	/// @param account_id Account id
	/// @return true if successful
	bool (*remove)(AccountDB* self, const uint32 account_id);

	/// Enables the web auth token for the given account id
	bool (*enable_webtoken)(AccountDB* self, const uint32 account_id);

	/// Disables the web auth token for the given account id
	bool (*disable_webtoken)(AccountDB* self, const uint32 account_id);

	/// Removes the web auth token for all accounts
	bool (*remove_webtokens)(AccountDB* self);

#ifdef VIP_ENABLE
	bool (*enable_monitor_vip)( AccountDB* self, const uint32 account_id, time_t vip_time );

	bool (*disable_monitor_vip)( AccountDB* self, const uint32 account_id );
#endif

	/// Modifies the data of an existing account.
	/// Uses acc->account_id to identify the account.
	///
	/// @param self Database
	/// @param acc Account data
	/// @param refresh_token Whether or not to refresh the web auth token
	/// @return true if successful
	bool (*save)(AccountDB* self, const struct mmo_account* acc, bool refresh_token);

	/// Finds an account with account_id and copies it to acc.
	///
	/// @param self Database
	/// @param acc Pointer that receives the account data
	/// @param account_id Target account id
	/// @return true if successful
	bool (*load_num)(AccountDB* self, struct mmo_account* acc, const uint32 account_id);

	/// Finds an account with userid and copies it to acc.
	///
	/// @param self Database
	/// @param acc Pointer that receives the account data
	/// @param userid Target username
	/// @return true if successful
	bool (*load_str)(AccountDB* self, struct mmo_account* acc, const char* userid);

	/// Returns a new forward iterator.
	///
	/// @param self Database
	/// @return Iterator
	AccountDBIterator* (*iterator)(AccountDB* self);
};

void mmo_send_global_accreg(AccountDB* self, int32 fd, uint32 account_id, uint32 char_id);
void mmo_save_global_accreg(AccountDB* self, int32 fd, uint32 account_id, uint32 char_id);

#endif /* ACCOUNT_HPP */
