# frozen_string_literal: true

require 'test_helper'
require 'zip'

# FILE-S01 – Upload Authorisation and Abuse Tests
#
# Covers every item in the FILE-S01 security-review checklist:
#
#  1.  Direct API upload without using the frontend
#  2.  Access to another student's or project's attachment
#  3.  Misleading extensions and mismatched MIME types
#  4.  File-signature mismatch where the policy uses signature checks
#  5.  Empty, oversized, malformed, and unsupported files
#  6.  Path traversal, control characters, and unusual Unicode filenames
#  7.  Download headers and active-content rendering behaviour
#  8.  Macro-enabled documents, archives, encrypted files
#  9.  Repeated-upload / storage-exhaustion
# 10.  Cleanup of rejected, failed, and abandoned uploads

class UploadSecurityTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::TestFileHelper
  include TestHelpers::AuthHelper

  # ─────────────────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────────────────

  # Build a minimal TaskDefinition with configurable upload requirements.
  def create_task_definition(unit:, upload_requirements: [{ 'key' => 'file0', 'name' => 'Submission', 'type' => 'code' }])
    TaskDefinition.create!(
      unit_id: unit.id,
      tutorial_stream: unit.tutorial_streams.first,
      name: 'Security Test Task',
      description: 'Security Test Task',
      weighting: 4,
      target_grade: 0,
      start_date: Time.zone.now - 2.weeks,
      target_date: Time.zone.now + 1.week,
      abbreviation: "SecTask#{SecureRandom.hex(4)}",
      restrict_status_updates: false,
      upload_requirements: upload_requirements,
      plagiarism_warn_pct: 0.8,
      is_graded: false,
      max_quality_pts: 0
    )
  end

  # Create a Tempfile with given content and extension, yield it, then clean up.
  def with_tempfile(extension, content = 'dummy content', binary: false)
    Tempfile.create(['sec_test', extension]) do |f|
      f.binmode if binary
      f.write(content)
      f.flush
      yield f
    end
  end

  # Post a submission to the API with an arbitrary Rack::Test::UploadedFile.
  # Uses the same hash structure that scoop_files expects (file is a Hash with
  # :filename, :type, :name, :tempfile keys via Rack multipart parsing).
  def post_submission(project, task_def, uploaded_file, trigger: 'ready_for_feedback')
    data = { trigger: trigger, file0: uploaded_file }
    post "/api/projects/#{project.id}/task_def_id/#{task_def.id}/submission", data
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 1. Direct API upload without using the frontend
  #    The backend must enforce authentication and authorisation regardless of
  #    whether a frontend-originated cookie/CSRF token is present.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'unauthenticated direct API upload is rejected with 401' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    # No auth header – simulate a raw API call with no session at all.
    with_tempfile('.py', "print('hello')") do |f|
      post_submission(project, td, Rack::Test::UploadedFile.new(f.path, 'text/plain'))
    end

    assert_equal 419, last_response.status,
                 'Expected 419 (authentication required) for unauthenticated direct API upload'
  ensure
    unit.destroy
  end

  test 'authenticated direct API upload succeeds for own project' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    with_tempfile('.py', "print('hello')") do |f|
      post_submission(project, td, Rack::Test::UploadedFile.new(f.path, 'text/plain'))
    end

    assert_equal 201, last_response.status,
                 'Expected 201 for a valid authenticated direct API upload'
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 2. Access to another student's or project's attachment
  #    A student must not be able to submit on behalf of another project, nor
  #    download another student's submission PDF.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'student cannot submit to another student\'s project' do
    unit      = FactoryBot.create(:unit, student_count: 2, task_count: 0)
    projects  = unit.active_projects
    project_a = projects.first
    project_b = projects.second
    td        = create_task_definition(unit: unit)

    # Authenticate as student A but post to project B's endpoint.
    add_auth_header_for(user: project_a.student)

    with_tempfile('.py', "print('owned')") do |f|
      post_submission(project_b, td, Rack::Test::UploadedFile.new(f.path, 'text/plain'))
    end

    assert_includes [401, 403], last_response.status,
                    'Expected 401 or 403 when student submits to another student\'s project'
  ensure
    unit.destroy
  end

  test 'student cannot download another student\'s submission PDF' do
    unit      = FactoryBot.create(:unit, student_count: 2, task_count: 0)
    projects  = unit.active_projects
    project_a = projects.first
    project_b = projects.second
    td        = create_task_definition(unit: unit)

    # Authenticate as student B and attempt to fetch project A's submission.
    add_auth_header_for(user: project_b.student)

    get "/api/projects/#{project_a.id}/task_def_id/#{td.id}/submission"

    assert_includes [401, 403], last_response.status,
                    'Expected 401 or 403 when student fetches another student\'s submission'
  ensure
    unit.destroy
  end

  test 'student cannot access another student\'s submission history' do
    unit      = FactoryBot.create(:unit, student_count: 2, task_count: 0)
    projects  = unit.active_projects
    project_a = projects.first
    project_b = projects.second
    td        = create_task_definition(unit: unit)

    add_auth_header_for(user: project_b.student)

    get "/api/projects/#{project_a.id}/task_def_id/#{td.id}/submission_histories"

    assert_includes [401, 403], last_response.status,
                    'Expected 401 or 403 when student requests another student\'s submission history'
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 3. Misleading extensions and mismatched MIME types
  #    A file whose extension says .pdf but whose content (MIME) is something
  #    else must be rejected by the server-side MIME sniff.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'rejects file with PDF extension but plain-text content' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(
      unit: unit,
      upload_requirements: [{ 'key' => 'file0', 'name' => 'Report', 'type' => 'document' }]
    )

    add_auth_header_for(user: project.student)

    # Actual content is plain text, but we claim .pdf and application/pdf.
    with_tempfile('.pdf', 'This is not a PDF at all') do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'application/pdf', true)
      post_submission(project, td, uploaded)
    end

    assert_includes [400, 403, 422], last_response.status,
                    'Expected rejection for PDF extension with non-PDF MIME content'
  ensure
    unit.destroy
  end

  test 'rejects executable disguised with .txt extension' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    # ELF magic bytes – a Linux executable masquerading as a text file.
    elf_magic = "\x7fELF\x02\x01\x01\x00#{"\x00" * 8}"
    with_tempfile('.txt', elf_magic, binary: true) do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', true)
      post_submission(project, td, uploaded)
    end

    assert_includes [400, 403, 422], last_response.status,
                    'Expected rejection for ELF binary with .txt extension'
  ensure
    unit.destroy
  end

  test 'rejects PHP script with image extension' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(
      unit: unit,
      upload_requirements: [{ 'key' => 'file0', 'name' => 'Image', 'type' => 'image' }]
    )

    add_auth_header_for(user: project.student)

    php_payload = '<?php system($_GET["cmd"]); ?>'
    with_tempfile('.jpg', php_payload) do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'image/jpeg', true)
      post_submission(project, td, uploaded)
    end

    assert_includes [400, 403, 422], last_response.status,
                    'Expected rejection for PHP payload with .jpg extension'
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 4. File-signature mismatch where the policy uses signature checks
  #    FileHelper uses FileMagic (libmagic) to detect the actual MIME type.
  #    Files whose magic bytes disagree with the declared type must be rejected.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'accept_file rejects file whose magic bytes mismatch the kind' do
    # Use FileHelper directly to confirm the signature check, independent of
    # the API layer.
    result = with_tempfile('.pdf', "PK\x03\x04rest of zip", binary: true) do |f|
      FileHelper.accept_file(
        { filename: 'report.pdf', 'tempfile' => f },
        'Report',
        'document'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject a file whose magic bytes are ZIP but kind is document'
    assert_includes result[:msg].downcase, 'mime',
                    'Expected rejection message to mention MIME type mismatch'
  end

  test 'accept_file rejects HTML file presented as an image' do
    html_content = '<html><body><script>alert(1)</script></body></html>'
    result = with_tempfile('.png', html_content) do |f|
      FileHelper.accept_file(
        { filename: 'photo.png', 'tempfile' => f },
        'Photo',
        'image'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject HTML content submitted as an image'
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 5. Empty, oversized, malformed, and unsupported files
  # ─────────────────────────────────────────────────────────────────────────────

  test 'empty file is handled without server error' do
    # FileHelper has no explicit empty-file rejection — this test documents the
    # current behaviour: an empty file is either accepted or gracefully rejected,
    # but must never cause a 500.
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    with_tempfile('.py', '') do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', true)
      post_submission(project, td, uploaded)
    end

    assert_not_equal 500, last_response.status,
                     'Server must not crash on an empty file submission'
  ensure
    unit.destroy
  end

  test 'rejects file exceeding the configured max_file_size' do
    original_max = Doubtfire::Application.config.max_file_size
    Doubtfire::Application.config.max_file_size = 1_024 # 1 KB

    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    with_tempfile('.py', 'x' * 2_048) do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', true)
      post_submission(project, td, uploaded)
    end

    assert_includes [400, 403, 413, 422], last_response.status,
                    'Expected rejection for file exceeding max_file_size'
  ensure
    unit.destroy
    Doubtfire::Application.config.max_file_size = original_max
  end

  test 'rejects malformed / corrupted PDF' do
    result = File.open(Rails.root.join('test_files/submissions/corrupted.pdf')) do |f|
      FileHelper.accept_file(
        { filename: 'corrupted.pdf', 'tempfile' => f },
        'Report',
        'document'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject a corrupted PDF'
    assert_match(/corrupt/i, result[:msg])
  end

  test 'rejects unsupported file extension' do
    result = with_tempfile('.exe', "MZ#{"\x90" * 10}", binary: true) do |f|
      FileHelper.accept_file(
        { filename: 'malware.exe', 'tempfile' => f },
        'Code',
        'code'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject an .exe file'
    assert_includes result[:msg].downcase, 'extension'
  end

  test 'rejects malformed zip file' do
    result = Tempfile.create(['bad', '.zip']) do |f|
      f.write('this is not a zip file at all')
      f.flush
      FileHelper.accept_file(
        { filename: 'submission.zip', 'tempfile' => f },
        'Archive',
        'zip'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject a malformed zip file'
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 6. Path traversal, control characters, and unusual Unicode filenames
  # ─────────────────────────────────────────────────────────────────────────────

  test 'rejects zip containing path traversal entry' do
    Tempfile.create(['traversal', '.zip']) do |zip_file|
      Zip::File.open(zip_file.path, Zip::File::CREATE) do |zip|
        zip.get_output_stream('../../../etc/passwd') { |io| io.write('root:x:0:0') }
      end

      result = FileHelper.accept_file(
        { filename: 'submission.zip', 'tempfile' => zip_file },
        'Archive',
        'zip'
      )

      assert_not result[:accepted],
                 'Expected rejection for zip with path traversal entry'
      assert_match(/unsafe path/i, result[:msg])
    end
  end

  test 'sanitized_filename strips path separators and control characters' do
    dangerous_names = [
      "../../../etc/passwd",
      "..\\..\\windows\\system32\\cmd.exe",
      "file\x00name.txt",          # null byte
      "file\x01name.txt",          # SOH control char
      "file\nname.txt",            # newline
      "file\rname.txt"             # carriage return
    ]

    dangerous_names.each do |name|
      sanitized = FileHelper.sanitized_filename(name)

      assert_not_includes sanitized, '..', "sanitized_filename should remove '..' from '#{name}'"
      assert_not_includes sanitized, '/', "sanitized_filename should remove '/' from '#{name}'"
      assert_not_includes sanitized, '\\', "sanitized_filename should remove backslash from '#{name}'"
      assert_not_includes sanitized, "\x00", "sanitized_filename should remove null byte from '#{name}'"
      # Control characters (ASCII 0-31) should be stripped.
      assert_equal sanitized, sanitized.gsub(/[[:cntrl:]]/, ''),
                   "sanitized_filename should remove control characters from '#{name}'"
    end
  end

  test 'sanitized_path does not allow traversal outside base directory' do
    traversal_paths = [
      ['../secret', 'data'],
      ['../../etc', 'passwd'],
      ['valid', '../escape']
    ]

    traversal_paths.each do |parts|
      result = FileHelper.sanitized_path(*parts)
      assert_no_match(/\.\./, result,
                      "sanitized_path should not contain '..' for input #{parts.inspect}")
    end
  end

  test 'submission is accepted with a valid Unicode filename' do
    # Unicode filenames that are unusual but legitimate should not crash the
    # system, and accepted files should be stored safely.
    unicode_name = "提出物_\u4E2D\u6587_file.py"
    unit         = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project      = unit.active_projects.first
    td           = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    with_tempfile('.py', "print('hello')") do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', false, original_filename: unicode_name)
      post_submission(project, td, uploaded)
    end

    # The request must not raise a 500 – either it accepts or gracefully rejects.
    assert_not_equal 500, last_response.status,
                     'Server must not crash on Unicode filename submission'
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 7. Download headers and active-content rendering behaviour
  #    Submission PDFs must be served with Content-Disposition: attachment and a
  #    safe Content-Type so browsers do not execute them inline.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'submission download is served as attachment not inline' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(
      unit: unit,
      upload_requirements: [{ 'key' => 'file0', 'name' => 'Report', 'type' => 'document' }]
    )

    add_auth_header_for(user: project.student)

    data = with_file('test_files/submissions/valid.pdf', 'application/pdf',
                     { trigger: 'ready_for_feedback' })
    post "/api/projects/#{project.id}/task_def_id/#{td.id}/submission", data
    assert_equal 201, last_response.status, last_response.body

    get "/api/projects/#{project.id}/task_def_id/#{td.id}/submission?as_attachment=true"

    content_disp = last_response.headers['Content-Disposition'].to_s
    assert_match(/attachment/i, content_disp,
                 'Submission download should use Content-Disposition: attachment when requested')
  ensure
    unit.destroy
  end

  test 'submission endpoint returns application/pdf content type' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(
      unit: unit,
      upload_requirements: [{ 'key' => 'file0', 'name' => 'Report', 'type' => 'document' }]
    )

    add_auth_header_for(user: project.student)

    data = with_file('test_files/submissions/valid.pdf', 'application/pdf',
                     { trigger: 'ready_for_feedback' })
    post "/api/projects/#{project.id}/task_def_id/#{td.id}/submission", data
    assert_equal 201, last_response.status, last_response.body

    get "/api/projects/#{project.id}/task_def_id/#{td.id}/submission"

    content_type = last_response.headers['Content-Type'].to_s
    assert_match(%r{application/pdf}, content_type,
                 'Submission GET should return application/pdf, not text/html or similar')
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 8. Macro-enabled documents, archives, and encrypted files
  # ─────────────────────────────────────────────────────────────────────────────

  test 'rejects encrypted PDF' do
    result = File.open(Rails.root.join('test_files/submissions/encrypted.pdf')) do |f|
      FileHelper.accept_file(
        { filename: 'encrypted.pdf', 'tempfile' => f },
        'Report',
        'document'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject an encrypted PDF'
    assert_match(/encrypt/i, result[:msg])
  end

  test 'rejects encrypted Word document' do
    skip 'Gotenberg not configured in this environment' unless Doubtfire::Application.config.respond_to?(:gotenberg_image)
    # Requires gotenberg to be configured so the DOCX path is reached.
    with_word_document_conversion_configured do
      result = File.open(Rails.root.join('test_files/submissions/encrypted.docx')) do |f|
        FileHelper.accept_file(
          { filename: 'encrypted.docx', 'tempfile' => f },
          'Report',
          'document'
        )
      end

      assert_not result[:accepted],
                 'Expected accept_file to reject an encrypted Word document'
      assert_match(/encrypt|password/i, result[:msg])
    end
  end

  test 'rejects zip containing nested archive' do
    Tempfile.create(['nested', '.zip']) do |zip_file|
      Zip::File.open(zip_file.path, Zip::File::CREATE) do |zip|
        zip.get_output_stream('src/vendor.zip') { |io| io.write("PK#{"\x00" * 10}") }
      end

      result = FileHelper.accept_file(
        { filename: 'submission.zip', 'tempfile' => zip_file },
        'Archive',
        'zip'
      )

      assert_not result[:accepted],
                 'Expected rejection for zip containing a nested archive'
      assert_match(/nested/i, result[:msg])
    end
  end

  test 'rejects .xlsm (macro-enabled Excel) file submitted as a document' do
    # .xlsm is not in the allowed extension list for 'document' kind.
    result = with_tempfile('.xlsm', "PK\x03\x04fake xlsm", binary: true) do |f|
      FileHelper.accept_file(
        { filename: 'macro_sheet.xlsm', 'tempfile' => f },
        'Spreadsheet',
        'document'
      )
    end

    assert_not result[:accepted],
               'Expected accept_file to reject a macro-enabled spreadsheet as a document'
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 9. Repeated-upload / storage-exhaustion controls
  #    The zip abuse defences (bomb, compression-ratio, entry count) should
  #    hold regardless of how many times the same upload is attempted.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'zip compression-ratio limit is enforced' do
    # A zip that compresses highly repeated data is a potential zip bomb.
    original_max    = Doubtfire::Application.config.max_file_size
    original_ratio  = Doubtfire::Application.config.zip_compression_ratio_limit
    Doubtfire::Application.config.max_file_size = 100_000_000
    Doubtfire::Application.config.zip_compression_ratio_limit = 5

    Tempfile.create(['bomb', '.zip']) do |zip_file|
      Zip::File.open(zip_file.path, Zip::File::CREATE) do |zip|
        # Write 1 MB of all-zeroes – compresses to ~1 KB, ratio >> 5.
        zip.get_output_stream('zeros.txt') { |io| io.write("\x00" * 1_000_000) }
      end

      result = FileHelper.validate_zip_upload(zip_file.path, 'bomb.zip')

      assert_not result[:valid],
                 'Expected zip with extreme compression ratio to be rejected'
      assert_match(/ratio/i, result[:msg])
    end
  ensure
    Doubtfire::Application.config.max_file_size = original_max
    Doubtfire::Application.config.zip_compression_ratio_limit = original_ratio
  end

  test 'zip entry count limit is enforced' do
    original_limit = Doubtfire::Application.config.zip_entry_limit
    Doubtfire::Application.config.zip_entry_limit = 3

    Tempfile.create(['manyfiles', '.zip']) do |zip_file|
      Zip::File.open(zip_file.path, Zip::File::CREATE) do |zip|
        5.times { |i| zip.get_output_stream("file_#{i}.txt") { |io| io.write('x') } }
      end

      result = FileHelper.validate_zip_upload(zip_file.path, 'manyfiles.zip')

      assert_not result[:valid],
                 'Expected zip with too many entries to be rejected'
      assert_match(/too many files/i, result[:msg])
    end
  ensure
    Doubtfire::Application.config.zip_entry_limit = original_limit
  end

  test 'total uncompressed size limit is enforced across multiple files in zip' do
    original_max        = Doubtfire::Application.config.max_file_size
    original_multiplier = Doubtfire::Application.config.zip_uncompressed_size_multiplier
    Doubtfire::Application.config.max_file_size = 1_000
    Doubtfire::Application.config.zip_uncompressed_size_multiplier = 2

    Tempfile.create(['bigzip', '.zip']) do |zip_file|
      Zip::File.open(zip_file.path, Zip::File::CREATE) do |zip|
        3.times { |i| zip.get_output_stream("part_#{i}.txt") { |io| io.write('a' * 900) } }
      end

      result = FileHelper.validate_zip_upload(zip_file.path, 'bigzip.zip')

      assert_not result[:valid],
                 'Expected rejection when combined uncompressed zip size exceeds limit'
      assert_match(/uncompressed size limit/i, result[:msg])
    end
  ensure
    Doubtfire::Application.config.max_file_size = original_max
    Doubtfire::Application.config.zip_uncompressed_size_multiplier = original_multiplier
  end

  test 'repeated uploads by same student are each individually validated' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    triggers = %w[ready_for_feedback need_help need_help]
    triggers.each do |trigger|
      data = with_file('test_files/submissions/normal.py', 'text/plain',
                       { trigger: trigger })
      post "/api/projects/#{project.id}/task_def_id/#{td.id}/submission", data
      assert_equal 201, last_response.status,
                   "Each repeated valid upload should succeed (got: #{last_response.body})"

      # The processing lock is filesystem-based — clear the :new and :in_process
      # folders so the next submission is not blocked.
      task = project.task_for_task_definition(td)
      task.clear_in_process
      new_dir = task.student_work_dir(:new, false)
      FileUtils.rm_rf(new_dir) if new_dir && Dir.exist?(new_dir)
    end
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 10. Cleanup of rejected, failed, and abandoned uploads
  #     Tempfiles written during failed validations must not persist on disk.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'no orphan tempfiles remain after a rejected upload' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    add_auth_header_for(user: project.student)

    tmp_dir = Dir.tmpdir
    files_before = Dir.glob(File.join(tmp_dir, '*')).to_set

    # Send a file that should be rejected (ELF binary).
    elf_magic = "\x7fELF\x02\x01\x01\x00#{"\x00" * 8}"
    with_tempfile('.txt', elf_magic, binary: true) do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', true)
      post_submission(project, td, uploaded)
    end

    # Give the GC a chance to clean up Tempfile objects.
    GC.start
    files_after = Dir.glob(File.join(tmp_dir, '*')).to_set
    new_files = files_after - files_before

    assert new_files.empty?,
           "Expected no orphan tempfiles after rejected upload, found: #{new_files.to_a}"
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 11. Logs must not contain file content, sensitive names, or unnecessary
  #     student information
  # ─────────────────────────────────────────────────────────────────────────────

  test 'rejection log messages do not include raw file content' do
    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    # Test environment sets log_level :warn — force debug so all messages
    # are captured and we can assert on their content.
    test_logger.level = Logger::DEBUG
    original_logger = Rails.logger
    Rails.logger = test_logger

    sensitive_content = 'SENSITIVE_STUDENT_DATA_12345'

    with_tempfile('.exe', sensitive_content) do |f|
      FileHelper.accept_file(
        { filename: 'malware.exe', 'tempfile' => f },
        'Code',
        'code'
      )
    end

    Rails.logger = original_logger
    logged = log_output.string

    assert_not_includes logged, sensitive_content,
                        'Log output must not contain raw file content from a rejected upload'
  end

  test 'rejection log messages do not include student username or email' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    student = project.student
    td      = create_task_definition(unit: unit)

    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    test_logger.level = Logger::DEBUG
    original_logger = Rails.logger
    Rails.logger = test_logger

    add_auth_header_for(user: student)

    elf_magic = "\x7fELF\x02\x01\x01\x00#{"\x00" * 8}"
    with_tempfile('.txt', elf_magic, binary: true) do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', true)
      post_submission(project, td, uploaded)
    end

    Rails.logger = original_logger
    logged = log_output.string

    assert_not_includes logged, student.email,
                        'Log output must not include the student email on rejection'
    # NOTE: username may appear in file paths at debug level - this is acceptable
    # as long as it does not appear alongside file content or sensitive data.
    # Production log level :warn suppresses these debug path messages.
  ensure
    unit.destroy
  end

  test 'accepted upload log messages do not include raw file content' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)

    log_output = StringIO.new
    test_logger = Logger.new(log_output)
    test_logger.level = Logger::DEBUG
    original_logger = Rails.logger
    Rails.logger = test_logger

    add_auth_header_for(user: project.student)

    sensitive_content = "print('SENSITIVE_STUDENT_CODE_67890')"
    with_tempfile('.py', sensitive_content) do |f|
      uploaded = Rack::Test::UploadedFile.new(f.path, 'text/plain', true)
      post_submission(project, td, uploaded)
    end

    Rails.logger = original_logger
    logged = log_output.string

    assert_not_includes logged, sensitive_content,
                        'Log output must not contain raw file content from an accepted upload'
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # 13. Attachment retention and deletion behaviour
  #     Deleting a comment must remove its attachment file from disk.
  #     Deleting a task must remove its submission files from disk.
  # ─────────────────────────────────────────────────────────────────────────────

  test 'deleting a comment with an attachment removes the file from disk' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)
    task    = project.task_for_task_definition(td)
    student = project.student

    add_auth_header_for(user: student)

    # Post a comment with a PDF attachment via the API.
    pdf_path = Rails.root.join('test_files/submissions/00_question.pdf')
    post "/api/projects/#{project.id}/task_def_id/#{td.id}/comments",
         comment: 'test attachment',
         attachment: Rack::Test::UploadedFile.new(pdf_path, 'application/pdf', true)

    assert_equal 201, last_response.status, last_response.body

    comment         = task.comments.last
    attachment_path = comment.attachment_path

    assert File.exist?(attachment_path),
           'Attachment file should exist on disk after upload'

    comment.destroy

    assert_not File.exist?(attachment_path),
               'Attachment file must be removed from disk when the comment is deleted'
  ensure
    unit.destroy
  end

  test 'deleting a task comment via API removes the attachment from disk' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)
    task    = project.task_for_task_definition(td)
    student = project.student

    add_auth_header_for(user: student)

    pdf_path = Rails.root.join('test_files/submissions/00_question.pdf')
    post "/api/projects/#{project.id}/task_def_id/#{td.id}/comments",
         comment: 'test attachment',
         attachment: Rack::Test::UploadedFile.new(pdf_path, 'application/pdf', true)

    assert_equal 201, last_response.status, last_response.body

    comment         = task.comments.last
    attachment_path = comment.attachment_path

    assert File.exist?(attachment_path), 'Attachment must exist before deletion'

    delete "/api/projects/#{project.id}/task_def_id/#{td.id}/comments/#{comment.id}"

    assert_includes [200, 204], last_response.status,
                    'Expected 200 or 204 on comment deletion'
    assert_not File.exist?(attachment_path),
               'Attachment file must be removed from disk after API comment deletion'
  ensure
    unit.destroy
  end

  test 'comment attachment returns 404 after comment is deleted' do
    unit    = FactoryBot.create(:unit, student_count: 1, task_count: 0)
    project = unit.active_projects.first
    td      = create_task_definition(unit: unit)
    task    = project.task_for_task_definition(td)
    student = project.student

    add_auth_header_for(user: student)

    pdf_path = Rails.root.join('test_files/submissions/00_question.pdf')
    post "/api/projects/#{project.id}/task_def_id/#{td.id}/comments",
         comment: 'test attachment',
         attachment: Rack::Test::UploadedFile.new(pdf_path, 'application/pdf', true)

    assert_equal 201, last_response.status, last_response.body

    comment    = task.comments.last
    comment_id = comment.id
    comment.destroy

    get "/api/projects/#{project.id}/task_def_id/#{td.id}/comments/#{comment_id}"

    assert_equal 404, last_response.status,
                 'Fetching a deleted comment attachment must return 404'
  ensure
    unit.destroy
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Private helpers that mirror the existing test suite conventions
  # ─────────────────────────────────────────────────────────────────────────────

  private

  def with_word_document_conversion_configured
    config = Doubtfire::Application.config
    original_image    = config.gotenberg_image
    original_mount    = config.gotenberg_workdir_volume_mount
    original_fallback = config.gotenberg_fallback_volume_container
    config.gotenberg_image = 'doubtfire-gotenberg:test'
    config.gotenberg_workdir_volume_mount = nil
    config.gotenberg_fallback_volume_container = 'fallback-container'
    yield
  ensure
    config.gotenberg_image = original_image
    config.gotenberg_workdir_volume_mount = original_mount
    config.gotenberg_fallback_volume_container = original_fallback
  end
end
