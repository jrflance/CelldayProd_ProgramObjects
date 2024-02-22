--liquibase formatted sql

--changeset KarinaMasihHudson:2d91fc13712f48b1a649d24938b9fcd2 stripComments:false runOnChange:true
/*=============================================
              :
       Author : Karina Masih-Hudson
              :
  Create Date : 2024-02-19
              :
  Description : Create Genmobile handset rebate file
              :
 SSIS Package : .dtsx
			  :
          Job :
              :
        Usage : EXEC upload.P_HandsetRebateGenmobile 49936
              :
 =============================================*/
CREATE OR ALTER PROC upload.P_HandsetRebateGenmobile
    (@FileID INT = 0)
AS

----testing
--DECLARE @FileID INT = 49936
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE
            @Separator VARCHAR(8),
            @TextDelimiter VARCHAR(8) = '"';
        SELECT
            @Separator = ft.Delimiter,
            @TextDelimiter = ft.ROWDelimiter
        FROM upload.tblFileType AS ft
        JOIN upload.tblFile AS f
            ON f.FileTypeID = ft.FileTypeID
        WHERE f.FileID = @FileID;


        TRUNCATE TABLE CellDayTemp.Upload.tblOutPutFile;
        INSERT INTO CellDayTemp.Upload.tblOutPutFile
        (
            Output
        )
        VALUES
        (
            -- noqa: disable=all
            'ReferenceNumber,DateFilled,Name,Price,PhoneNumber,SIM,OrderType,MasterAgentID,MasterAgentName,StoreID,StoreName,ESN,Rebate'
            -- noqa: enable=all
        );

        DROP TABLE IF EXISTS #tmp;

        CREATE TABLE #tmp
        (
            ReferenceNumber INT,
            DateFilled DATETIME,
            [Name] NVARCHAR(255),
            Price DECIMAL(9, 2),
            PhoneNumber NVARCHAR(200),
            SIM NVARCHAR(200),
            OrderType NVARCHAR(50),
            MasterAgentID INT,
            MasterAgentName NVARCHAR(50),
            StoreID INT,
            StoreName NVARCHAR(50),
            ESN NVARCHAR(200),
            Rebate DECIMAL(9, 2)
        );

        DECLARE
            @StartDate DATETIME = DATEADD(WK, DATEDIFF(WK, 0, GETDATE()), -7)
            , @EndDate DATETIME = DATEADD(WK, DATEDIFF(WK, 0, GETDATE()), -0);

        INSERT INTO #tmp
        (
            ReferenceNumber,
            DateFilled,
            Name,
            Price,
            PhoneNumber,
            SIM,
            OrderType,
            MasterAgentID,
            MasterAgentName,
            StoreID,
            StoreName,
            ESN,
            Rebate
        )
        EXEC [Report].[P_Report_HandsetRebateByCarrier] @StartDate, @EndDate, 270;
        WITH CTEFinal AS (
            SELECT
                CONVERT(
                    VARCHAR(8000),
                    Tracfone.fnEdiRows(
                        @Separator,
                        '',
                        '',
                        SUB.ReferenceNumber,
                        FORMAT(SUB.DateFilled, 'yyyy-MM-dd hh:mm:ss'),
                        SUB.Name,
                        SUB.Price,
                        SUB.PhoneNumber,
                        SUB.SIM,
                        SUB.OrderType,
                        SUB.MasterAgentID,
                        SUB.MasterAgentName,
                        SUB.StoreID,
                        SUB.StoreName,
                        SUB.ESN,
                    -- noqa: disable=all
                        SUB.Rebate,
					DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT
                    -- noqa: enable=all
                    )
                ) AS PlainText
            FROM #tmp AS SUB
        )
        INSERT INTO upload.OutPutFile
        (
            Output
        )
        SELECT PlainText
        FROM CTEFinal AS SUB;

        DROP TABLE #tmp;
        DECLARE
            @CNT INT =
            (
                SELECT COUNT(*) FROM CellDayTemp.Upload.tblOutPutFile
            );
        SET @CNT = IIF(@CNT < 2, 2, @CNT);
        SELECT @CNT AS RecordCount;
    END TRY
    BEGIN CATCH
        DECLARE
            @ERRMSG VARCHAR(200) =
            (
                SELECT ERROR_MESSAGE()
            );

        UPDATE f
        SET
            f.FileStatus = -1,
            f.ErrorInfo = @ERRMSG
        FROM upload.tblFile AS f
        WHERE FileID = @FileID

        SELECT 0 AS RecordCount
        ; THROW;
    END CATCH
END;
