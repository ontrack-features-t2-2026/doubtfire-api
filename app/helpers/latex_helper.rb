require 'digest'
require 'fileutils'

module LatexHelper
  def self.included(controller)
    controller.helper_method :latex_asset_path if controller.respond_to?(:helper_method)
  end

  # TeX runs in an isolated helper which only sees this job's shared work
  # directory. Copy the referenced bytes instead of exposing student-work or
  # writing absolute host paths into the document/newpax preamble.
  # The controller supplies a work id for each render; its cache is render-local.
  # rubocop:disable Rails/HelperInstanceVariable
  def latex_asset_path(source)
    work_id = @work_id.to_s
    raise ArgumentError, 'Invalid LaTeX work directory' unless work_id.match?(/\A[a-zA-Z0-9_()-]+\z/)

    source = File.expand_path(source.to_s)
    raise ArgumentError, 'LaTeX source asset does not exist' unless File.file?(source)

    @latex_staged_assets ||= {}
    @latex_staged_assets[source] ||= begin
      extension = File.extname(source).downcase.gsub(/[^.a-z0-9]/, '_')

      relative = "assets/#{Digest::SHA256.hexdigest(source)}#{extension}"
      destination = File.join(LatexToPdf.config.fetch(:basedir), work_id, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
      relative
    end
  end
  # rubocop:enable Rails/HelperInstanceVariable

  def generate_pdf(template:)
    raise 'LATEX_CONTAINER_NAME is not set' if ENV['LATEX_CONTAINER_NAME'].nil?
    raise 'LATEX_BUILD_PATH is not set' if ENV['LATEX_BUILD_PATH'].nil?
    render_to_string(template: template, layout: true)
  end
end
