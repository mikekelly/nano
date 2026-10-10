import json, os, sys, time
mode = sys.argv[1]
if mode == 'stubborn':
    import signal
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(json.dumps({'pid': os.getpid()}), flush=True)
    while True: time.sleep(1)
elif mode == 'invalid':
    print('not json', flush=True)
elif mode == 'array':
    print('[]', flush=True)
elif mode == 'huge':
    sys.stdout.write('x' * 200); sys.stdout.flush()
elif mode == 'partial':
    sys.stdout.write('{'); sys.stdout.flush()
elif mode == 'exit':
    sys.exit(7)
else:
    sys.stderr.write('diagnostic, not JSON\n'); sys.stderr.flush()
    for line in sys.stdin:
        msg = json.loads(line)
        if mode == 'context':
            msg = {'cwd': os.getcwd(), 'env': os.environ['MCP_TEST_VALUE'], 'arg': sys.argv[2]}
        encoded = (json.dumps(msg, ensure_ascii=False) + '\n').encode()
        if mode == 'split':
            for byte in encoded:
                os.write(1, bytes([byte])); time.sleep(.001)
        elif mode == 'multi':
            os.write(1, encoded + encoded)
        else:
            os.write(1, encoded)
