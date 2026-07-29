# Rules for Commit messages

- If the user asked you to read this file, treat that as them asking you to
  perform the prodedure described below.

- We should never be doing active work in the main branch. If we're in the main
   branch, do not commit or push. Alert the user.

- Commit messages should follow Conventional Commits format:
   https://www.conventionalcommits.org/en/v1.0.0/
   And qoomon's commit message style guide:
   https://gist.github.com/qoomon/5dfcdf8eec66a051ecd85625518cfd13
   Fetch both pages at least once every session. Do not rely on memory alone.

- When commits are needed, write all proposed commits to .local/next_commit.md,
   (overwrite any existing contents) open the file in code, and wait for the
   user to approve.

   Example:
   ```
   --- <use --- to divide commits>
   AGENTS.md <use relative file paths>
   AGENTS.TESTING.md
   tests/conftest.py

   docs(testing): condense test instructions

   Cut repetition and restatement from the test sections without
   changing any gate, flag, or command.
   ---
   tests/test_thing.py

   tests(thing): added live tests

   <message goes here>
   ---
   ```

- After the user's approval, reread the file and commit the user's versions.
   Clear the contents of the file when done.

- After committing, if we're in a non-main branch, push to origin.
