import unittest
from audit_writes import audit

class AuditWritesTest(unittest.TestCase):
    def test_children_resumed_relative_fd_and_symlink_destinations(self):
        lines = [
            '1 chdir("/private/sub") = 0',
            '1 clone(child_stack=NULL, flags=CLONE_VM) = 2',
            '2 openat(AT_FDCWD</private/sub>, "new", O_WRONLY|O_CREAT <unfinished ...>',
            '2 <... openat resumed>) = 4</outside/target>',
            '2 fchmod(4</outside/target>, 0600) = 0',
            '2 renameat(5</private/a>, "old", 6</private/b>, "new") = 0',
        ]
        result = audit(lines, '/other', ['/private'])
        self.assertFalse(result['passed'])
        self.assertEqual(result['outside'], ['/outside/target'])
        self.assertIn('/private/sub/new', result['paths'])
        self.assertIn('/private/b/new', result['paths'])
        self.assertEqual(result['parse_errors'], [])

    def test_shared_thread_cwd_and_fd_aliases_are_resolved(self):
        result = audit([
            '1 clone(child_stack=NULL, flags=CLONE_FS) = 2',
            '2 chdir("/private/new") = 0',
            '1 mkdir("relative", 0700) = 0',
            '1 openat(AT_FDCWD</private/new>, "/proc/self/fd/2", O_WRONLY) = 4</private/log>',
            '1 openat(AT_FDCWD</private/new>, "/dev/null", O_WRONLY) = 5</dev/null<char 1:3>>',
        ], '/other', ['/private'])
        self.assertTrue(result['passed'])
        self.assertIn('/private/new/relative', result['paths'])
        self.assertIn('/private/log', result['paths'])
        self.assertNotIn('/proc/self/fd/2', result['paths'])

    def test_unparsed_mutation_fails_closed(self):
        self.assertFalse(audit(['1 mkdir("/private/new", 0700) = ?'], '/private', ['/private'])['passed'])

    def test_read_and_failed_writes_do_not_claim_mutation(self):

        result = audit(['1 openat(AT_FDCWD</outside>, "file", O_RDONLY) = 3</outside/file>',
                        '1 unlink("/outside/missing") = -1 ENOENT (No such file)',
                        '1 openat(AT_FDCWD</outside>, "/dev/null", O_WRONLY) = 4</dev/null>'], '/cwd', ['/private'])
        self.assertTrue(result['passed'])
        self.assertEqual(result['failed_operations'], 1)
        self.assertEqual(result['special_devices'], ['/dev/null'])

    def test_unresolved_fd_and_unfinished_mutation_fail_closed(self):
        self.assertFalse(audit(['1 fchmod(3, 0600) = 0'], '/private', ['/private'])['passed'])
        self.assertFalse(audit(['1 mkdir("/private/a", 0700 <unfinished ...>'], '/private', ['/private'])['passed'])

if __name__ == '__main__': unittest.main()
