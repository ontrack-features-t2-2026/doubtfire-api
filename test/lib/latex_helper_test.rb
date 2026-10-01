# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class LatexHelperTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir('ontrack-latex-assets')
    @previous_basedir = LatexToPdf.config[:basedir]
    LatexToPdf.config[:basedir] = File.join(@directory, 'shared')
    @helper = Object.new.extend(LatexHelper)
    @helper.instance_variable_set(:@work_id, 'test-job')
  end

  teardown do
    LatexToPdf.config[:basedir] = @previous_basedir
    FileUtils.remove_entry(@directory)
  end

  test 'stages distinct relative assets without exposing source paths or copying unrelated files' do
    first = write_asset('student-a/report.pdf', '%PDF-first')
    second = write_asset('student-b/report.pdf', '%PDF-second')
    write_asset('student-a/private.pdf', 'Unrelated file')
    first_relative = @helper.latex_asset_path(first)
    second_relative = @helper.latex_asset_path(second)

    assert_match(%r{\Aassets/[0-9a-f]{64}\.pdf\z}, first_relative)
    assert_not_equal first_relative, second_relative
    assert_equal first_relative, @helper.latex_asset_path(first)
    assert_equal '%PDF-first', File.binread(File.join(LatexToPdf.config[:basedir], 'test-job', first_relative))
    assert_equal '%PDF-second', File.binread(File.join(LatexToPdf.config[:basedir], 'test-job', second_relative))
    assert_equal 2, Dir.glob(File.join(LatexToPdf.config[:basedir], 'test-job/assets/*')).length
    assert_not_includes first_relative, 'student-a'
  end

  test 'rejects work directory traversal and missing assets' do
    source = write_asset('source.pdf', '%PDF-first')
    @helper.instance_variable_set(:@work_id, '../escape')
    assert_raises(ArgumentError) { @helper.latex_asset_path(source) }
    @helper.instance_variable_set(:@work_id, 'test-job')
    assert_raises(ArgumentError) { @helper.latex_asset_path(File.join(@directory, 'missing.pdf')) }
  end

  test 'stages code with punctuation in its extension or no extension' do
    source = write_asset('source.c++', 'int main() {}')
    relative = @helper.latex_asset_path(source)
    assert_match(%r{\Aassets/[0-9a-f]{64}\.c__\z}, relative)
    assert_equal 'int main() {}', File.read(File.join(LatexToPdf.config[:basedir], 'test-job', relative))
    source = write_asset('Dockerfile', 'FROM scratch')
    relative = @helper.latex_asset_path(source)
    assert_match(%r{\Aassets/[0-9a-f]{64}\z}, relative)
  end

  test 'task render shares the same staged path between pdfpages and newpax' do
    unit = create(:unit, student_count: 1, task_count: 1)
    task = unit.active_projects.first.task_for_task_definition(unit.task_definitions.first)
    task.task_definition.update!(upload_requirements: [{ 'key' => 'file0', 'name' => 'Demo document', 'type' => 'document' }])
    source = write_asset('student-work/private/source.pdf', '%PDF-source')
    controller = Task::TaskAppController.new
    {
      task: task, files: [{ path: source, type: 'document', truncated: false }],
      image_path: Rails.root.join('public/assets/images'), work_id: 'render-test-job',
      institution_name: 'Synthetic test', doubtfire_product_name: 'OnTrack', include_pax: true
    }.each { |name, value| controller.instance_variable_set("@#{name}", value) }

    rendered = nil
    converter = lambda { |code, _config|
      rendered = code
      '%PDF-rendered'
    }
    FileHelper.stub(:pages_in_pdf, 1) do
      LatexToPdf.stub(:generate_pdf, converter) do
        controller.render_to_string(template: '/task/task_pdf', layout: true)
      end
    end
    relative = controller.latex_asset_path(source)
    assert_includes rendered, "\\includepdf[pages={1-1},fitpaper]{#{relative}}"
    assert_includes rendered, "newpax.writenewpax(\"#{relative.delete_suffix('.pdf')}\")"
    assert_not_includes rendered, File.dirname(source)
    assert File.file?(File.join(LatexToPdf.config[:basedir], 'render-test-job', relative))
  end

  private

  def write_asset(name, bytes)
    path = File.join(@directory, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end
end
