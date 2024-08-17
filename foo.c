#include <stdio.h>
#include <bits/stdc++.h>
using namespace std;

extern "C" bool glob_match(char const *pat, char const *str)
{
	/*
	 * Backtrack to previous * on mismatch and retry starting one
	 * character later in the string.  Because * matches all characters
	 * (no exception for /), it can be easily proved that there's
	 * never a need to backtrack multiple levels.
	 */
	char const *back_pat = NULL, *back_str;

	/*
	 * Loop over each token (character or cclass) in pat, matching
	 * it against the remaining unmatched tail of str.  Return false
	 * on mismatch, or true after matching the trailing nul bytes.
	 */
    const char* sentinel = str + strlen(str);
	for (;;) {
//        assert(str <= sentinel);
		unsigned char c = *str++;
		unsigned char d = *pat++;
        printf("c=0X%02X %c   d= 0X%02X %c\n", c, c, d, d);

		switch (d) {
		case '?':	/* Wildcard: anything but nul */
			if (c == '\0')
				return false;
			break;
		case '*':	/* Any-length wildcard */
			if (*pat == '\0')	/* Optimize trailing * case */
				return true;
			back_pat = pat;
			back_str = --str;	/* Allow zero-length match */
			break;
		case '[': {	/* Character cclass */
			bool match = false, inverted = (*pat == '!');
			char const *cclass = pat + inverted;
			unsigned char a = *cclass++;

			/*
			 * Iterate over each span in the character cclass.
			 * A span is either a single character a, or a
			 * range a-b.  The first span may begin with ']'.
			 */
			do {
				unsigned char b = a;

				if (a == '\0')	/* Malformed */
					goto literal;

				if (cclass[0] == '-' && cclass[1] != ']') {
					b = cclass[1];

					if (b == '\0')
						goto literal;

					cclass += 2;
					/* Any special action if a > b? */
				}
				match |= (a <= c && c <= b);
			} while ((a = *cclass++) != ']');

			if (match == inverted)
				goto backtrack;
			pat = cclass;
			}
			break;
		case '\\':
			d = *pat++;
//			fallthrough;
		default:	/* Literal character */
literal:
			if (c == d) {
				if (d == '\0')
					return true;
				break;
			}
backtrack:
			if (c == '\0' || !back_pat)
				return false;	/* No point continuing */
			/* Try again from last *, one character later in str. */
			pat = back_pat;
			str = ++back_str;
			break;
		}
	}
}
// Function to check if a string matches a given pattern
int isMatch(string s, string p)
{
    int sLen = s.length(), pLen = p.length();
    int sIdx = 0, pIdx = 0;
    int starIdx = -1, sTmpIdx = -1;

    // Iterate through the string and pattern
    while (sIdx < sLen) {
        // If the pattern character matches the string
        // character or the pattern character is '?'
        if (pIdx < pLen
            && (p[pIdx] == '?' || p[pIdx] == s[sIdx])) {
            ++sIdx;
            ++pIdx;
        }
        // If the pattern character is '*'
        else if (pIdx < pLen && p[pIdx] == '*') {
            // Record the position of '*' and the current
            // string index
            starIdx = pIdx;
            sTmpIdx = sIdx;
            ++pIdx;
        }
        // If there is no match and no previous '*' to
        // backtrack to
        else if (starIdx == -1) {
            return 0;
        }
        // If there is a previous '*' to backtrack to
        else {
            // Backtrack to the last '*'
            pIdx = starIdx + 1;
            sIdx = sTmpIdx + 1;
            sTmpIdx = sIdx;
        }
    }

    // Ensure remaining characters in the pattern are all
    // '*'
    for (int i = pIdx; i < pLen; i++) {
        if (p[i] != '*') {
            return 0;
        }
    }
    return 1;
}

// Driver code
int main()
{

    string pattern = "m*issip*i";
//    string str = "baaabab";
    string str = "mississippi";
    glob_match("abcdefg[!g]*x", "abcdefg\0xxxxxx");
    glob_match("abcdefg[!g][!g][!g][!g]", "abcdefg\0xxxxxx");

    // Check if the string matches the pattern
    cout << isMatch(str, pattern);

    return 0;
}
