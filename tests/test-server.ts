#!/usr/bin/env bun

/**
 * Test HTTP Server for Prozy Proxy
 * 
 * This server provides various endpoints to test proxy functionality:
 * - Basic GET/POST requests
 * - Different status codes
 * - Headers handling
 * - Request/response body echo
 * - Delayed responses for timeout testing
 */

const server = Bun.serve({
  port: 3003,
  fetch(req) {
    const url = new URL(req.url);
    const method = req.method;
    const path = url.pathname;

    console.log(`\n📥 Incoming request: ${method} ${path}`);
    console.log('   Query:', Object.fromEntries(url.searchParams));
    const headerLog: Record<string, string> = {};
    req.headers.forEach((value, key) => {
      headerLog[key] = value;
    });
    console.log('   Headers:', headerLog);

    // Route handler
    if (path === '/') {
      return new Response('Hello from Test Server! This is the root endpoint.', {
        status: 200,
        headers: {
          'Content-Type': 'text/plain',
          'Server': 'Bun-Test-Server',
          'X-Test-Header': 'root-response'
        }
      });
    }

    if (path === '/echo') {
      // Echo back the request method and headers
      const headers: Record<string, string> = {};
      req.headers.forEach((value, key) => {
        headers[key] = value;
      });

      const body = {
        method: method,
        path: path,
        headers: headers,
        timestamp: new Date().toISOString(),
        query: Object.fromEntries(url.searchParams)
      };

      return new Response(JSON.stringify(body, null, 2), {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'X-Echo-Response': 'true'
        }
      });
    }

    if (path === '/post' && method === 'POST') {
      return req.text().then(body => {
        console.log('   POST body:', body);
        const response = {
          received: body,
          length: body.length,
          content_type: req.headers.get('content-type') || 'unknown',
          timestamp: new Date().toISOString()
        };

        return new Response(JSON.stringify(response, null, 2), {
          status: 201,
          headers: {
            'Content-Type': 'application/json',
            'X-Post-Response': 'created'
          }
        });
      });
    }

    if (path === '/status') {
      const status = url.searchParams.get('code') || '200';
      const statusCode = parseInt(status);
      
      return new Response(`Status ${statusCode} response`, {
        status: statusCode,
        headers: {
          'Content-Type': 'text/plain',
          'X-Status-Test': statusCode.toString()
        }
      });
    }

    if (path === '/delay') {
      const delay = parseInt(url.searchParams.get('ms') || '1000');
      
      return new Promise(resolve => {
        setTimeout(() => {
          resolve(new Response(`Delayed response after ${delay}ms`, {
            status: 200,
            headers: {
              'Content-Type': 'text/plain',
              'X-Delay': delay.toString()
            }
          }));
        }, delay);
      });
    }

    if (path === '/headers') {
      // Return all request headers as JSON
      const headers: Record<string, string> = {};
      req.headers.forEach((value, key) => {
        headers[key] = value;
      });

      return new Response(JSON.stringify(headers, null, 2), {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'X-Headers-Test': 'true'
        }
      });
    }

    if (path === '/json') {
      const data = {
        message: 'This is a JSON response',
        nested: {
          array: [1, 2, 3, 4, 5],
          object: {
            key: 'value',
            number: 42
          }
        },
        timestamp: new Date().toISOString(),
        server: 'Bun Test Server'
      };

      return new Response(JSON.stringify(data, null, 2), {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'X-JSON-Response': 'true'
        }
      });
    }

    if (path === '/redirect') {
      const target = url.searchParams.get('to') || '/';
      return new Response(null, {
        status: 302,
        headers: {
          'Location': target,
          'X-Redirect-Test': 'true'
        }
      });
    }

    // 404 for unknown paths
    return new Response(`Not Found: ${method} ${path}`, {
      status: 404,
      headers: {
        'Content-Type': 'text/plain',
        'X-Error': 'not-found'
      }
    });
  },

  error(error) {
    console.error('Server error:', error);
    return new Response('Internal Server Error', {
      status: 500,
      headers: {
        'Content-Type': 'text/plain',
        'X-Error': 'internal-server-error'
      }
    });
  }
});

console.log(`🚀 Test server running on http://localhost:${server.port}`);
console.log('\nAvailable endpoints:');
console.log('  GET  /           - Simple text response');
console.log('  GET  /echo       - Echo request info as JSON');
console.log('  POST /post       - Echo POST body as JSON');
console.log('  GET  /status?code=404  - Custom status code');
console.log('  GET  /delay?ms=2000    - Delayed response');
console.log('  GET  /headers    - Return request headers');
console.log('  GET  /json       - Sample JSON response');
console.log('  GET  /redirect?to=/echo  - Redirect to target');
console.log('\nUse Ctrl+C to stop the server');
