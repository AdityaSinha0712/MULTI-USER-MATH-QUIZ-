#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>

// --- Configuration ---
const char *ssid = "MEE_Math_Challenge";
const char *password = "";
const byte DNS_PORT = 53;
IPAddress apIP(192, 168, 4, 1);
#define MAX_USERS 60  // Maximum simultaneous players

// --- Global Objects ---
WebServer server(80);
DNSServer dnsServer;
Preferences preferences;

// --- Enums ---
enum NodeType { NODE_OPERATOR, NODE_VALUE };
enum AppState { STATE_LOGIN, STATE_PLAYING, STATE_STATS };

// --- Data Structures ---
struct ExprNode {
    NodeType type;
    union { char op; int val; } data;
    ExprNode *left;
    ExprNode *right;
};

// **SESSION STRUCTURE** (Holds ALL game data for ONE user)
struct Session {
    String id;             // Unique Cookie ID
    unsigned long lastActive; // To cleanup old users
    bool active;           // Is this slot in use?

    // Game State specific to this user
    String username;
    AppState currentState;
    int currentRating;
    int currentAnswer;
    String currentEquation;
    unsigned long questionStartTime;
    int timeLimit;
    String feedbackMsg;
    String feedbackColor;
    
    // Stats
    int correctCount;
    int wrongCount;
    int totalQuestions;
    float timeHistory[50]; 
    bool resultHistory[50];
};

// Array of sessions (The "Database" in RAM)
Session sessions[MAX_USERS];

// --- Math Engine (Stateless) ---
void free_tree(ExprNode* node) {
    if (!node) return;
    free_tree(node->left);
    free_tree(node->right);
    delete node;
}

int eval_tree(ExprNode* node) {
    if (!node) return 0;
    if (node->type == NODE_VALUE) return node->data.val;
    int l = eval_tree(node->left);
    int r = eval_tree(node->right);
    switch (node->data.op) {
        case '+': return l + r;
        case '-': return l - r;
        case '*': return l * r;
        case '/': return (r != 0) ? l / r : 0;
    }
    return 0;
}

void buildEquationString(ExprNode* node, String &s) {
    if (!node) return;
    if (node->type == NODE_VALUE) {
        s += String(node->data.val);
    } else {
        s += "(";
        buildEquationString(node->left, s);
        s += " " + String(node->data.op) + " ";
        buildEquationString(node->right, s);
        s += ")";
    }
}

ExprNode* generate_problem(int depth) {
    ExprNode* node = new ExprNode();
    if (depth == 0) {
        node->type = NODE_VALUE;
        node->data.val = (random(1, 15));
        node->left = node->right = NULL;
    } else {
        char ops[] = {'+', '-', '*'};
        node->type = NODE_OPERATOR;
        node->data.op = ops[random(0, 3)];
        node->left = generate_problem(depth - 1);
        node->right = generate_problem(depth - 1);
    }
    return node;
}

// --- Session Manager ---

// Find the session belonging to the current client request
Session* getSession() {
    if (server.hasHeader("Cookie")) {
        String cookie = server.header("Cookie");
        if (cookie.indexOf("ESPSESSIONID=") != -1) {
            String id = cookie.substring(cookie.indexOf("ESPSESSIONID=") + 13);
            id = id.substring(0, id.indexOf(";")); // Handle if there are other cookies
            
            for (int i = 0; i < MAX_USERS; i++) {
                if (sessions[i].active && sessions[i].id == id) {
                    sessions[i].lastActive = millis();
                    return &sessions[i];
                }
            }
        }
    }
    return NULL; // No valid session found
}

// Create a new session for a user
Session* createSession() {
    // 1. Find an empty slot or overwrite the oldest inactive one
    int slot = -1;
    unsigned long oldestTime = millis();
    
    for (int i = 0; i < MAX_USERS; i++) {
        if (!sessions[i].active) {
            slot = i;
            break;
        }
        if (sessions[i].lastActive < oldestTime) {
            oldestTime = sessions[i].lastActive;
            slot = i;
        }
    }

    // 2. Initialize the slot
    Session* s = &sessions[slot];
    s->active = true;
    s->id = String(random(0xffff), HEX) + String(millis(), HEX); // Random ID
    s->lastActive = millis();
    s->currentState = STATE_LOGIN;
    s->username = "";
    
    // Clear history
    for(int k=0; k<50; k++) { s->timeHistory[k]=0; s->resultHistory[k]=false; }
    
    return s;
}

// --- Game Logic (Modified to take Session* s) ---

void nextQuestion(Session* s) {
    int depth = 1;
    if (s->currentRating > 1300) depth = 2;
    if (s->currentRating > 1600) depth = 3;
    
    s->timeLimit = 10 + (depth * 5);

    ExprNode* root = generate_problem(depth);
    s->currentAnswer = eval_tree(root);
    s->currentEquation = "";
    buildEquationString(root, s->currentEquation);
    free_tree(root);
    
    s->questionStartTime = millis();
}

void startNewGame(Session* s, String name) {
    s->username = name;
    s->currentRating = preferences.getInt("rating", 1200); // Note: Sharing global rating DB for now
    s->correctCount = 0;
    s->wrongCount = 0;
    s->totalQuestions = 0;
    s->feedbackMsg = "Welcome, " + name + "!";
    s->feedbackColor = "#28a745";
    s->currentState = STATE_PLAYING;
    nextQuestion(s);
}

void processAnswer(Session* s, int userAnswer) {
    unsigned long timeTaken = millis() - s->questionStartTime;
    float seconds = timeTaken / 1000.0;
    
    if (s->totalQuestions < 50) s->timeHistory[s->totalQuestions] = seconds;

    bool isCorrect = (userAnswer == s->currentAnswer);
    bool isTimeout = (seconds > s->timeLimit);

    if (isTimeout) isCorrect = false;

    if (s->totalQuestions < 50) s->resultHistory[s->totalQuestions] = isCorrect;
    
    // Elo Update logic
    double expected = 1.0 / (1.0 + pow(10, (1200 - s->currentRating) / 400.0));
    int k = 32;
    int change = (int)(k * ((isCorrect ? 1 : 0) - expected));
    if (isCorrect && seconds < (s->timeLimit * 0.5)) change += 5;
    
    s->currentRating += change;
    // preferences.putInt("rating", s->currentRating); // Disabled to prevent users overwriting each other's persistent DB

    if (isTimeout) {
        s->feedbackMsg = "Too Slow! Answer: " + String(s->currentAnswer);
        s->feedbackColor = "#dc3545";
        s->wrongCount++;
    } else if (isCorrect) {
        s->feedbackMsg = "Correct! (" + String(seconds, 1) + "s)";
        s->feedbackColor = "#28a745";
        s->correctCount++;
    } else {
        s->feedbackMsg = "Wrong. Answer: " + String(s->currentAnswer);
        s->feedbackColor = "#dc3545";
        s->wrongCount++;
    }

    s->totalQuestions++;
    nextQuestion(s);
}

// --- HTML Generators ---

String getHead() {
    String s = "<!DOCTYPE html><html><head><meta name='viewport' content='width=device-width, initial-scale=1'>";
    s += "<style>";
    s += "body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #eef2f3; margin: 0; padding: 20px; text-align: center; }";
    s += ".container { max-width: 500px; margin: auto; background: white; padding: 30px; border-radius: 15px; box-shadow: 0 10px 25px rgba(0,0,0,0.1); }";
    s += "h1 { color: #333; margin-bottom: 5px; }";
    s += "input { width: 80%; padding: 15px; margin: 15px 0; border: 2px solid #ddd; border-radius: 8px; font-size: 18px; text-align: center; }";
    s += "button { width: 100%; padding: 15px; border: none; border-radius: 8px; font-size: 18px; font-weight: bold; cursor: pointer; transition: 0.3s; margin-top: 10px; }";
    s += ".btn-primary { background: #007bff; color: white; }";
    s += ".btn-danger { background: #dc3545; color: white; }";
    s += ".equation { font-size: 28px; font-weight: bold; color: #444; margin: 20px 0; padding: 15px; background: #f8f9fa; border-radius: 10px; }";
    s += ".feedback { font-weight: bold; margin-bottom: 15px; font-size: 1.1em; }";
    s += "table { width: 100%; border-collapse: collapse; margin-top: 20px; }";
    s += "th, td { padding: 10px; border-bottom: 1px solid #ddd; text-align: center; }";
    s += "th { background-color: #f8f9fa; }";
    s += "</style></head><body><div class='container'>";
    return s;
}

void handleRoot() {
    Session* s = getSession();
    
    // If no session found or invalid cookie, treat as Login
    if (s == NULL) {
        String html = getHead();
        html += "<h1>MEE Login</h1><p>Enter your name to begin.</p>";
        html += "<form action='/login' method='POST'>";
        html += "<input type='text' name='username' placeholder='Your Name' required autofocus>";
        html += "<button type='submit' class='btn-primary'>Start Session</button>";
        html += "</form></div></body></html>";
        server.send(200, "text/html", html);
        return;
    }

    // Render based on user's specific state
    if (s->currentState == STATE_LOGIN) {
         // Should have been handled above, but just in case
         server.sendHeader("Location", "/login", true);
         server.send(302, "text/plain", "");
    }
    else if (s->currentState == STATE_PLAYING) {
        String html = getHead();
        html += "<div style='display:flex; justify-content:space-between; color:#777; font-size:0.9em;'>";
        html += "<span>User: " + s->username + "</span><span>Rating: " + String(s->currentRating) + "</span></div>";
        html += "<div class='feedback' style='color:" + s->feedbackColor + "'>" + s->feedbackMsg + "</div>";
        html += "<div class='equation'>" + s->currentEquation + " = ?</div>";
        
        html += "<form action='/submit' method='POST'>";
        html += "<input type='number' name='answer' placeholder='?' required autocomplete='off' autofocus>";
        html += "<button type='submit' class='btn-primary'>Submit Answer</button>";
        html += "</form>";
        
        html += "<form action='/exit' method='POST'>";
        html += "<button type='submit' class='btn-danger' style='margin-top:20px;'>Exit & Finish</button>";
        html += "</form>";
        html += "<p style='color:#999; font-size:0.8em; margin-top:20px;'>Time Limit: " + String(s->timeLimit) + "s</p>";
        html += "</div></body></html>";
        server.send(200, "text/html", html);
    }
    else if (s->currentState == STATE_STATS) {
        float totalTime = 0;
        for(int i=0; i<s->totalQuestions; i++) totalTime += s->timeHistory[i];
        float avgTime = (s->totalQuestions > 0) ? (totalTime / s->totalQuestions) : 0;

        String html = getHead();
        html += "<h1>Session Results</h1>";
        html += "<h2>User: <span style='color:#007bff'>" + s->username + "</span></h2>";
        html += "<div style='background:#e9ecef; padding:10px; border-radius:8px;'>Final Rating: <strong>" + String(s->currentRating) + "</strong></div>";
        html += "<br>Avg Time: <strong>" + String(avgTime, 2) + "s</strong>";

        html += "<h3>History</h3><table><tr><th>Q#</th><th>Result</th><th>Time</th></tr>";
        for(int i=0; i<s->totalQuestions; i++) {
            String color = s->resultHistory[i] ? "green" : "red";
            String res = s->resultHistory[i] ? "Correct" : "Wrong";
            html += "<tr><td>" + String(i+1) + "</td><td style='color:" + color + "'>" + res + "</td><td>" + String(s->timeHistory[i], 2) + "s</td></tr>";
        }
        html += "</table>";
        
        html += "<form action='/login' method='POST'>"; // Re-use login route to reset
        html += "<button type='submit' class='btn-primary' name='logout' value='1'>Start New User</button>";
        html += "</form></div></body></html>";
        server.send(200, "text/html", html);
    }
}

// --- Form Handlers (All check session first) ---

void handleLogin() {
    // If "logout" button was pressed, just redirect to clear state
    if (server.hasArg("logout")) {
         // We don't strictly delete the session, just ignore it and let client clear cookie or create new one
         // But effectively we create a NEW session below
    }

    if (server.hasArg("username")) {
        // 1. Create a NEW session slot
        Session* s = createSession();
        
        // 2. Initialize it
        startNewGame(s, server.arg("username"));
        
        // 3. Send the Cookie to the browser so we remember them
        // "ESPSESSIONID=..."
        String cookieHeader = "ESPSESSIONID=" + s->id + "; Path=/; HttpOnly";
        server.sendHeader("Set-Cookie", cookieHeader);
        server.sendHeader("Location", "/", true);
        server.send(302, "text/plain", "");
    } else {
        server.sendHeader("Location", "/", true);
        server.send(302, "text/plain", "");
    }
}

void handleSubmit() {
    Session* s = getSession();
    if (s && s->currentState == STATE_PLAYING && server.hasArg("answer")) {
        processAnswer(s, server.arg("answer").toInt());
    }
    server.sendHeader("Location", "/", true);
    server.send(302, "text/plain", "");
}

void handleExit() {
    Session* s = getSession();
    if (s) {
        s->currentState = STATE_STATS;
        
        // Serial Reporting
        Serial.println("\n--- USER FINISHED ---");
        Serial.println("User: " + s->username);
        Serial.println("Rating: " + String(s->currentRating));
        Serial.println("Score: " + String(s->correctCount) + "/" + String(s->totalQuestions));
        Serial.println("---------------------");
    }
    server.sendHeader("Location", "/", true);
    server.send(302, "text/plain", "");
}

void handleNotFound() {
    server.sendHeader("Location", "/", true);
    server.send(302, "text/plain", "");
}

// --- Setup ---

void setup() {
    Serial.begin(115200);
    preferences.begin("mee_app", false);
    
    // Initialize sessions to inactive
    for(int i=0; i<MAX_USERS; i++) sessions[i].active = false;

    // WiFi
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(apIP, apIP, IPAddress(255, 255, 255, 0));
    WiFi.softAP(ssid, password);

    // DNS & Server
    dnsServer.start(DNS_PORT, "*", apIP);

    // Important: We must collect the "Cookie" header
    const char *headerkeys[] = {"Cookie"};
    size_t headerkeyssize = sizeof(headerkeys) / sizeof(char*);
    server.collectHeaders(headerkeys, headerkeyssize);

    server.on("/", handleRoot);
    server.on("/login", HTTP_POST, handleLogin);
    server.on("/submit", HTTP_POST, handleSubmit);
    server.on("/exit", HTTP_POST, handleExit);
    server.onNotFound(handleNotFound);
    
    server.begin();
    Serial.println("MEE Multi-User Engine Ready.");
}

void loop() {
    dnsServer.processNextRequest();
    server.handleClient();
}


