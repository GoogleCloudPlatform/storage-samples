#!/usr/bin/env python3
"""Serverless GCNV ONTAP XML File Audit Collector for Google Cloud Logging."""

from datetime import datetime, timezone
import glob
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
import threading
import time
import xml.etree.ElementTree as ET
from google.cloud import logging as cloud_logging

AUDIT_MOUNT_DIR = os.environ.get("AUDIT_MOUNT_DIR", "/mnt/audit_logs")
LOG_NAME = os.environ.get("LOG_NAME", "gcnv-smb-file-audit")
POLL_INTERVAL_SEC = int(os.environ.get("POLL_INTERVAL_SEC", "15"))
DELETE_AFTER_INGEST = os.environ.get("DELETE_AFTER_INGEST", "true").lower() == "true"
STORAGE_POOL = os.environ.get("STORAGE_POOL_NAME", "unknown-pool")
GCNV_LOCATION = os.environ.get("GCNV_LOCATION", "unknown-location")

NS = {"ev": "http://schemas.microsoft.com/win/2004/08/events/event"}

class HealthHandler(BaseHTTPRequestHandler):
  def do_GET(self):
    self.send_response(200)
    self.end_headers()
    self.wfile.write(b"OK")

  def log_message(self, format, *args):
    return

def strip_ns(tag):
  return tag.split("}", 1)[-1] if "}" in tag else tag

def parse_event_element(event_elem):
  sys_data = {}
  ev_data = {}
  for child in event_elem:
    cname = strip_ns(child.tag)
    if cname == "System":
      for s in child:
        sname = strip_ns(s.tag)
        if sname == "Provider":
          sys_data["provider"] = s.attrib.get("Name", "")
        elif sname == "TimeCreated":
          sys_data["time_created"] = s.attrib.get("SystemTime", "")
        elif sname == "Security":
          sys_data["user_id"] = s.attrib.get("UserID", "")
        else:
          sys_data[sname.lower()] = (s.text or "").strip()
    elif cname == "EventData":
      for d in child:
        if strip_ns(d.tag) == "Data":
          key = d.attrib.get("Name", "unknown")
          ev_data[key] = (d.text or "").strip()

  result = sys_data.get("result", "")
  severity = "WARNING" if "Failure" in result else "INFO"

  payload = {
      "event_id": int(sys_data.get("eventid", "0")) if sys_data.get("eventid", "0").isdigit() else sys_data.get("eventid", ""),
      "event_name": sys_data.get("eventname", ""),
      "source_protocol": sys_data.get("source", "SMB"),
      "result": result,
      "svm": sys_data.get("computer", ""),
      "storage_pool": STORAGE_POOL,
      "location": GCNV_LOCATION,
      "user_name": ev_data.get("SubjectUserName", ""),
      "domain_name": ev_data.get("SubjectDomainName", ""),
      "user_sid": ev_data.get("SubjectUserSid", ""),
      "client_ip": ev_data.get("SubjectIP", ev_data.get("IpAddress", ev_data.get("ClientIP", ""))),
      "object_type": ev_data.get("ObjectType", ""),
      "object_name": ev_data.get("ObjectName") or ev_data.get("NewPath") or ev_data.get("OldPath", ""),
      "old_path": ev_data.get("OldPath", ""),
      "new_path": ev_data.get("NewPath", ""),
      "share_name": ev_data.get("ShareName", ""),
      "access_mask": ev_data.get("AccessMask", ""),
      "access_list": ev_data.get("AccessList", ""),
      "handle_id": ev_data.get("HandleID", ev_data.get("HandleId", "")),
      "event_record_id": sys_data.get("eventrecordid", ""),
      "time_created": sys_data.get("time_created", ""),
      "raw_event_data": ev_data,
  }
  return payload, severity

def process_xml_file(filepath, logger):
  count = 0
  # Use iterparse so even large 50MB XML files stream with minimal memory
  for _, elem in ET.iterparse(filepath, events=("end",)):
    if strip_ns(elem.tag) == "Event":
      payload, severity = parse_event_element(elem)
      logger.log_struct(
          payload,
          severity=severity,
          labels={
              "svm": str(payload.get("svm", "")),
              "event_id": str(payload.get("event_id", "")),
              "protocol": str(payload.get("source_protocol", "SMB")),
          },
      )
      count += 1
      elem.clear()
  return count

def poll_loop():
  client = cloud_logging.Client()
  logger = client.logger(LOG_NAME)
  print(f"==> Starting GCNV SMB Audit Collector watching {AUDIT_MOUNT_DIR} -> Cloud Logging ({LOG_NAME})")

  while True:
    try:
      # Match only rotated XML files (audit_<svm>_D<date>_T<time>*.xml), skipping active *_last.xml
      pattern = os.path.join(AUDIT_MOUNT_DIR, "audit_*_D*.xml")
      for filepath in sorted(glob.glob(pattern)):
        if filepath.endswith("_last.xml"):
          continue
        try:
          ingested = process_xml_file(filepath, logger)
          if ingested > 0:
            print(f"==> Ingested {ingested} SMB audit events from {os.path.basename(filepath)}")
          if DELETE_AFTER_INGEST:
            os.remove(filepath)
        except Exception as file_err:
          print(f"WARN: Failed processing {filepath}: {file_err}")
    except Exception as loop_err:
      print(f"ERROR in poll_loop: {loop_err}")
    time.sleep(POLL_INTERVAL_SEC)

if __name__ == "__main__":
  port = int(os.environ.get("PORT", "8080"))
  server = HTTPServer(("0.0.0.0", port), HealthHandler)
  threading.Thread(target=server.serve_forever, daemon=True).start()
  poll_loop()
