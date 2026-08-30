# frozen_string_literal: true

require 'test_helper'

class Batch03DocxAttachmentTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include TestHelpers::AuthHelper
  include TestHelpers::JsonHelper

  DOCX_MIME_TYPE = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'

  def app
    Rails.application
  end

  def setup
    super
    @project = FactoryBot.create(:project)
    @student = @project.student
    @task_definition = @project.unit.task_definitions.first
    @task = @project.task_for_task_definition(@task_definition)
    @comments_endpoint = "/api/projects/#{@project.id}/task_def_id/#{@task_definition.id}/comments"
    @docx_path = Rails.root.join('test_files/TestWordDoc.docx')
    add_auth_header_for(user: @student)
  end

  def docx_upload(filename: 'Phone evidence.docx')
    Rack::Test::UploadedFile.new(
      @docx_path,
      DOCX_MIME_TYPE,
      true,
      original_filename: filename
    )
  end

  test 'uploads and downloads DOCX with exact bytes and attachment metadata' do
    original_bytes = File.binread(@docx_path)
    original_filename = 'Phone evidence original.docx'

    post @comments_endpoint,
         comment: 'Evidence captured on phone',
         attachment: docx_upload(filename: original_filename),
         client_request_id: SecureRandom.uuid

    assert_equal 201, last_response.status, last_response.body
    response = last_response_body
    comment = TaskComment.find(response.fetch('id'))

    assert_equal 'document', comment.content_type
    assert_equal '.docx', comment.attachment_extension
    assert_equal original_filename, comment.attachment_file_name
    assert_equal DOCX_MIME_TYPE, comment.attachment_mime_type
    assert_equal original_bytes.bytesize, comment.attachment_size
    assert_equal original_bytes, File.binread(comment.attachment_path)

    assert_equal true, response['has_attachment']
    assert_equal 'document', response['type']
    assert_equal original_filename, response['attachment_file_name']
    assert_equal DOCX_MIME_TYPE, response['attachment_mime_type']
    assert_equal original_bytes.bytesize, response['attachment_byte_size']

    get "#{@comments_endpoint}/#{comment.id}"

    assert_equal 200, last_response.status, last_response.body
    assert_equal original_bytes, last_response.body
    assert_match(/\A#{Regexp.escape(DOCX_MIME_TYPE)}(?:;|\z)/, last_response.headers['Content-Type'].to_s)
    assert_match(/attachment/i, last_response.headers['Content-Disposition'].to_s)
    assert_includes last_response.headers['Content-Disposition'].to_s, original_filename
  ensure
    comment&.destroy
  end

  test 'repeating a client request id returns the same comment and creates one row' do
    client_request_id = SecureRandom.uuid
    initial_count = @task.comments.where(user_id: @student.id, client_request_id: client_request_id).count

    post @comments_endpoint,
         attachment: docx_upload,
         client_request_id: client_request_id

    assert_equal 201, last_response.status, last_response.body
    first_response = last_response_body

    post @comments_endpoint,
         attachment: docx_upload(filename: 'Retry should not replace original.docx'),
         client_request_id: client_request_id

    assert_equal 201, last_response.status, last_response.body
    second_response = last_response_body

    assert_equal first_response['id'], second_response['id']
    assert_equal initial_count + 1,
                 @task.comments.where(user_id: @student.id, client_request_id: client_request_id).count
    assert_equal 'Phone evidence.docx', TaskComment.find(first_response['id']).attachment_file_name
  ensure
    TaskComment.where(task: @task, user: @student, client_request_id: client_request_id).destroy_all if client_request_id
  end

  test 'repeating a text client request id returns the same comment and creates one row' do
    client_request_id = SecureRandom.uuid
    initial_count = @task.comments.where(user_id: @student.id, client_request_id: client_request_id).count

    post_json @comments_endpoint,
              comment: 'Typed once while uploading several attachments',
              client_request_id: client_request_id

    assert_equal 201, last_response.status, last_response.body
    first_response = last_response_body

    post_json @comments_endpoint,
              comment: 'Typed once while uploading several attachments',
              client_request_id: client_request_id

    assert_equal 201, last_response.status, last_response.body
    second_response = last_response_body

    assert_equal first_response['id'], second_response['id']
    assert_equal initial_count + 1,
                 @task.comments.where(user_id: @student.id, client_request_id: client_request_id).count
  ensure
    TaskComment.where(task: @task, user: @student, client_request_id: client_request_id).destroy_all if client_request_id
  end

  test 'serves a stored Unicode HTML-like filename with RFC 5987 download disposition' do
    supplied_filename = 'evidence <draft>.DOCX'
    stored_filename = '📱 evidence <draft>.DOCX'

    post @comments_endpoint,
         attachment: docx_upload(filename: supplied_filename),
         client_request_id: SecureRandom.uuid

    assert_equal 201, last_response.status, last_response.body
    comment = TaskComment.find(last_response_body.fetch('id'))
    assert_equal supplied_filename, comment.attachment_file_name
    comment.update!(attachment_original_filename: stored_filename)
    comment.reload

    assert_equal stored_filename, comment.attachment_file_name
    assert_operator comment.attachment_file_name.length, :<=, 255
    assert_equal comment.attachment_file_name.gsub(/[[:cntrl:]]/, ''), comment.attachment_file_name
    assert_not_includes comment.attachment_file_name, '/'

    get "#{@comments_endpoint}/#{comment.id}"

    assert_equal 200, last_response.status, last_response.body
    disposition = last_response.headers['Content-Disposition'].to_s
    assert_match(/\Aattachment;/i, disposition)
    assert_match(/filename\*=UTF-8''/i, disposition)
    assert_match(/%F0%9F%93%B1/i, disposition)
    assert_no_match(/[\r\n]/, disposition)
  ensure
    comment&.destroy
  end

  test 'rejects an attachment exactly at the 30MB boundary without creating a comment' do
    initial_count = @task.comments.count

    Tempfile.create(['batch03-size-boundary', '.docx']) do |tempfile|
      tempfile.truncate(30_000_000)
      tempfile.flush

      post @comments_endpoint,
           attachment: Rack::Test::UploadedFile.new(
             tempfile.path,
             DOCX_MIME_TYPE,
             true,
             original_filename: 'at-limit.docx'
           ),
           client_request_id: SecureRandom.uuid
    end

    assert_includes 400..499, last_response.status, last_response.body
    assert_match(/maximum attachment size of 30MB/i, last_response_body.fetch('error'))
    assert_equal initial_count, @task.comments.count
  end

  test 'a different student cannot download the DOCX attachment' do
    unit = FactoryBot.create(:unit, student_count: 2)
    owner_project, other_project = unit.active_projects.first(2)
    task_definition = unit.task_definitions.first
    endpoint = "/api/projects/#{owner_project.id}/task_def_id/#{task_definition.id}/comments"

    add_auth_header_for(user: owner_project.student)
    post endpoint,
         attachment: docx_upload,
         client_request_id: SecureRandom.uuid

    assert_equal 201, last_response.status, last_response.body
    comment = TaskComment.find(last_response_body.fetch('id'))

    add_auth_header_for(user: other_project.student)
    get "#{endpoint}/#{comment.id}"

    assert_equal 403, last_response.status, last_response.body
    assert_match(/cannot read the comments/i, last_response_body.fetch('error'))
  ensure
    comment&.destroy
    unit&.destroy
  end

  test 'a DOCX storage failure leaves no task comment row' do
    initial_count = @task.comments.count
    move_failure = lambda do |_source, _destination|
      raise IOError, 'simulated Batch03 storage failure'
    end

    FileUtils.stub(:mv, move_failure) do
      post @comments_endpoint,
           attachment: docx_upload,
           client_request_id: SecureRandom.uuid
    end

    assert_includes 500..599, last_response.status, last_response.body
    assert_equal initial_count, @task.comments.count
  end

  test 'unsupported attachment returns a controlled 4xx without creating a comment' do
    initial_count = @task.comments.count
    invalid_upload = Rack::Test::UploadedFile.new(
      Rails.root.join('test_files/submissions/test.txt'),
      'text/plain',
      true,
      original_filename: 'unsupported.txt'
    )

    post @comments_endpoint,
         attachment: invalid_upload,
         client_request_id: SecureRandom.uuid

    assert_includes 400..499, last_response.status, last_response.body
    assert_match(/not an acceptable format/i, last_response_body.fetch('error'))
    assert_equal initial_count, @task.comments.count
  end
end
