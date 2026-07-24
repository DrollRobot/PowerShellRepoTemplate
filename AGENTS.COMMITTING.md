# Rules for Commit messages

- We should never be doing active work in the main branch. If we're in the main
   branch, do not commit or push. Alert the user.

- Commit messages should follow Conventional Commits format:
   https://www.conventionalcommits.org/en/v1.0.0/
   And qoomon's commit message style guide:
   https://gist.github.com/qoomon/5dfcdf8eec66a051ecd85625518cfd13
   Fetch both pages at least once every session. Do not rely on memory alone.

- When commits are needed, for each commit write the relative file paths
   followed by the message in .local/next_commit.md, and wait for the user
   to approve. (overwrite any existing contents)
   Example:
   ```
   ---
   AGENTS.md
   AGENTS.TESTING.md
   tests/conftest.py

   docs(testing): condense test instructions

   Cut repetition and restatement from the test sections without
   changing any gate, flag, or command.
   ---
   tests/test_thing.py

   test(thing): add live tests

   <message>
   ---
   ```

- After the user's approved, reread the file and commit the user's versions.
   Clear the contents of the file when done.

- After committing, if we're in a non-main branch, push to origin.
