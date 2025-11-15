#!/usr/bin/env bun

/**
 * End-to-End Test for Prozy Proxy
 * 
 * This test:
 * 1. Starts the Bun test server
 * 2. Starts the Zig proxy 
 * 3. Runs various curl tests through the proxy
 * 4. Verifies responses
 * 5. Cleans up processes
 */

import { spawn } from 'child_process';
import { promisify } from 'util';

const sleep = promisify(setTimeout);

class ProcessManager {
  private processes: Array<{ name: string; process: any }> = [];

  async start(name: string, command: string, args: string[], readyPattern?: string): Promise<void> {
    console.log(`🚀 Starting ${name}...`);
    
    const child = spawn(command, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    child.stdout?.on('data', (data: Buffer) => {
      const text = data.toString();
      stdout += text;
      if (readyPattern && text.includes(readyPattern)) {
        console.log(`✅ ${name} is ready`);
      }
    });

    child.stderr?.on('data', (data: Buffer) => {
      stderr += data.toString();
    });

    child.on('error', (error: any) => {
      console.error(`❌ ${name} failed to start:`, error.message);
      throw error;
    });

    this.processes.push({ name, process: child });

    // Wait for startup
    await sleep(2000);
    console.log(`✅ ${name} started`);
  }

  async stopAll() {
    console.log('\n🧹 Cleaning up processes...');
    for (const { name, process } of this.processes) {
      try {
        process.kill('SIGTERM');
        console.log(`✅ Stopped ${name}`);
      } catch (error) {
        console.error(`❌ Failed to stop ${name}:`, error);
      }
    }
    await sleep(500);
  }
}

async function curlTest(url: string, description: string): Promise<{ stdout: string; status: number }> {
  console.log(`\n🧪 Testing: ${description}`);
  console.log(`   Request: GET ${url}`);
  
  try {
    const response = await fetch(url, { 
      timeout: 10000,
      verbose: false 
    });
    const text = await response.text();
    
    console.log(`   Status: ${response.status}`);
    console.log(`   Response: ${text.substring(0, 100)}${text.length > 100 ? '...' : ''}`);
    
    return { stdout: text, status: response.status };
  } catch (error: any) {
    console.log(`   ❌ Error: ${error.message}`);
    throw error;
  }
}

async function runTests() {
  const pm = new ProcessManager();
  
  try {
    // Start test server
    await pm.start('Test Server', 'bun', ['tests/test-server.ts'], 'Test server running');
    
    // Start proxy
    await pm.start('Proxy', 'zig', ['build', 'run'], 'proxy listening on');
    
    // Test if server is responding directly
    console.log('\n🔍 Testing direct server connection...');
    try {
      const directResponse = await fetch('http://localhost:3003/');
      console.log(`   ✅ Direct server connection: ${directResponse.status}`);
    } catch (error: any) {
      console.log(`   ❌ Direct server connection failed: ${error.message}`);
    }
    
    // Test if proxy is responding
    console.log('\n🔍 Testing proxy connection...');
    let proxyReady = false;
    for (let i = 0; i < 10; i++) {
      try {
        const proxyResponse = await fetch('http://localhost:8080/', { timeout: 2000 });
        console.log(`   ✅ Proxy connection: ${proxyResponse.status}`);
        proxyReady = true;
        break;
      } catch (error: any) {
        console.log(`   ⏳ Proxy not ready yet, retrying... (${i + 1}/10)`);
        await sleep(1000);
      }
    }
    
    if (!proxyReady) {
      throw new Error('Proxy failed to become ready after 10 attempts');
    }

    console.log('\n🎯 Running E2E Tests for Prozy Proxy');
    console.log('=====================================');

    const proxyTests = [
      { url: 'http://localhost:8080/', description: 'Basic root endpoint' },
      { url: 'http://localhost:8080/echo', description: 'Echo request information' },
      { url: 'http://localhost:8080/json', description: 'JSON response handling' },
      { url: 'http://localhost:8080/status?code=404', description: 'Custom status code' },
      { url: 'http://localhost:8080/headers', description: 'Headers passthrough' },
    ];

    for (const test of proxyTests) {
      await curlTest(test.url, test.description);
    }
    
    // Test 6: Delay test (with timeout)
    console.log('\n🧪 Testing: Delayed response');
    try {
      const start = Date.now();
      const response = await fetch('http://localhost:8080/delay?ms=1000');
      const duration = Date.now() - start;
      const text = await response.text();
      console.log(`   Duration: ${duration}ms`);
      console.log(`   Status: ${response.status}`);
      console.log(`   Response: ${text}`);
    } catch (error: any) {
      console.log(`   Error: ${error.message}`);
    }

    console.log('\n🧪 Testing: Concurrent delayed responses');
    {
      const count = 5;
      const delayMs = 1000;
      const start = Date.now();
      const requests = Array.from({ length: count }, () =>
        fetch(`http://localhost:8080/delay?ms=${delayMs}`)
      );
      const responses = await Promise.all(requests);
      const duration = Date.now() - start;

      for (const response of responses) {
        if (!response.ok) {
          throw new Error(`Concurrent delay request failed with status ${response.status}`);
        }
      }

      if (duration > delayMs * 3) {
        throw new Error(`Concurrent delay test too slow: ${duration}ms for ${count} requests`);
      }

      console.log(`   Completed ${count} concurrent delayed requests in ${duration}ms`);
    }

    console.log('\n🧪 Testing: POST body echo via proxy');
    {
      const body = 'hello via proxy';
      const response = await fetch('http://localhost:8080/post', {
        method: 'POST',
        body,
        headers: {
          'Content-Type': 'text/plain',
        },
      });
      const json = await response.json();

      if (response.status !== 201) {
        throw new Error(`Expected status 201 for POST /post, got ${response.status}`);
      }
      if (json.received !== body) {
        throw new Error(`Echo body mismatch: expected "${body}", got "${json.received}"`);
      }

      console.log('   POST echo test passed');
    }

    console.log('\n🧪 Testing: Large POST body through proxy');
    {
      const size = 64 * 1024;
      const body = 'x'.repeat(size);
      const response = await fetch('http://localhost:8080/post', {
        method: 'POST',
        body,
        headers: {
          'Content-Type': 'text/plain',
        },
      });
      const json = await response.json();

      if (response.status !== 201) {
        throw new Error(`Expected status 201 for large POST /post, got ${response.status}`);
      }
      if (json.length !== size) {
        throw new Error(`Expected echoed length ${size}, got ${json.length}`);
      }

      console.log('   Large POST echo test passed');
    }

    console.log('\n✅ E2E Tests Completed Successfully!');
    
  } catch (error: any) {
    console.error('\n❌ Test failed:', error.message);
    console.error('Stack:', error.stack);
    process.exit(1);
  } finally {
    await pm.stopAll();
  }
}

// Handle cleanup on exit
process.on('SIGINT', async () => {
  console.log('\n\n🛑 Received SIGINT, cleaning up...');
  process.exit(0);
});

process.on('SIGTERM', async () => {
  console.log('\n\n🛑 Received SIGTERM, cleaning up...');
  process.exit(0);
});

// Run the tests
runTests().catch(console.error);
