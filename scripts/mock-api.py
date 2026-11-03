"""Test fixture for Chat Completions. Prefixes the source instead of translating it."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/v1/models?fixture=1":
            self.send_error(404)
            return
        if self.headers.get("Authorization") != "Bearer fixture-model-key":
            self.send_error(401)
            return
        self.send_json({"data": [{"id": "sample-model-10", "name": "Sample Ten"},
                                 {"id": "sample-model-2"}, {"id": "sample-model-2"}, {"id": " "}]})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        user = request["messages"][-1]["content"]
        if user == "Say OK.":
            content = "OK"
        else:
            payload = json.loads(user)
            if payload.get("task") == "classify":
                rows = [{"id": row["id"], "category": "自然语言处理", "keywords": ["注意力", "注意力", "Transformer"],
                         "kind": "conference", "venue": "NeurIPS", "publicationYear": 2017 if "Attention" in row["title"] else 2099,
                         "evidence": "NeurIPS 2017"} for row in payload["documents"]]
                rows.append({"id": "not-in-library", "category": "主题", "keywords": [], "kind": "journal"})
                answer = {"classifications": rows}
            elif payload.get("task") == "search":
                rows = [{"id": row["id"], "score": 94, "reason": "使用注意力机制"}
                        for row in payload["documents"] if "Attention" in row["title"]]
                rows.append({"id": "not-in-library", "score": 99, "reason": "无效编号"})
                answer = {"matches": rows}
            else:
                answer = {index: "译文 " + text for index, text in payload["excerpts"].items()}
            content = json.dumps(answer, ensure_ascii=False)
        self.send_json({"choices": [{"message": {"content": content}}]})

    def send_json(self, value):
        response = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), Handler).serve_forever()
