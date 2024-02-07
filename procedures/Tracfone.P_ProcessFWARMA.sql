--liquibase formatted sql

--changeset KarinaMasihHudson:42295670-3b3b-4fb7-a041-f7c7861cc4f1 stripComments:false runOnChange:true

/*=============================================
       Author : Karina Masih-Hudson
  Create Date : 2024-01-17
  Description : Process FWA RMAs from file TF sends
 SSIS Package : SSIS_Tracfone_Processing > Process_FWA_RMA.dtsx
          Job :
        Usage : EXEC [Tracfone].[P_ProcessFWARMAs] NULL
 =============================================*/
CREATE OR ALTER PROC tracfone.P_ProcessFWARMAs
    (@FileID INT)
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        DECLARE @FileTypeID INT = (SELECT TOP 1 filetypeid FROM upload.tblFile WHERE FileID = @FileID)

        DECLARE
            @Delimiter VARCHAR(8) =
            (
                SELECT u.Delimiter
                FROM upload.tblFileType AS u
                WHERE u.FileTypeID = @FileTypeID
            );

        INSERT INTO Tracfone.tblFWA_RMA_Decision
        (
            Account_ID,
            Act_Order_No,
            Act_DateOrdered,
            Act_OrderTotal,
            Act_Product_ID,
            Act_Name,
            IMEI,
            MIN_MDN,
            REMOTE_TRANS_ID,
            Return_Order_No,
            Return_DateOrdered,
            Return_OrderTotal,
            TBV_DECISION,
            FileID,
            RowProcessed
        )
        SELECT
            A.Chr1,
            A.Chr2,
            A.Chr3,
            A.Chr4,
            A.Chr5,
            A.Chr6,
            A.Chr7,
            A.Chr8,
            A.Chr9,
            A.Chr10,
            A.Chr11,
            A.Chr12,
            REPLACE(A.Chr13, CHAR(10), '') AS TBV_DECISION,
            t.FileID,
            0 AS RowProcessed
        FROM upload.tblPlainTextFiles AS t
        CROSS APPLY dbo.SplitText(t.txt, @Delimiter, '"') AS A
        WHERE t.FileID = @FileID AND TRY_CAST(A.Chr2 AS INT) IS NOT NULL;


        DROP TABLE IF EXISTS #ProcessOrders
        SELECT *
        INTO #ProcessOrders
        FROM Tracfone.tblFWA_RMA_Decision
        WHERE FileID = @FileID

        DROP TABLE IF EXISTS #OrderIssues

        CREATE TABLE #OrderIssues (RMA_Order_No INT, Error VARCHAR(50))

        IF
            EXISTS
            (
                SELECT 1
                FROM #ProcessOrders AS rma
                JOIN dbo.Order_No AS od
                    ON od.Order_No = rma.Return_Order_No
                WHERE od.Filled = 1
            )
            BEGIN
                INSERT INTO #OrderIssues
                (RMA_Order_No, Error)
                SELECT rma.Return_Order_No, 'Order is already filled' AS Error
                FROM #ProcessOrders AS rma
                JOIN dbo.Order_No AS od
                    ON od.Order_No = rma.Return_Order_No
                WHERE od.Filled = 1
            END;

        IF
            EXISTS
            (
                SELECT 1
                FROM #ProcessOrders AS rma
                JOIN dbo.Order_No AS od
                    ON od.Order_No = rma.Return_Order_No
                WHERE od.Void = 1
            )
            BEGIN
                INSERT INTO #OrderIssues
                (RMA_Order_No, Error)
                SELECT rma.Return_Order_No, 'Order is already voided' AS Error
                FROM #ProcessOrders AS rma
                JOIN dbo.Order_No AS od
                    ON od.Order_No = rma.Return_Order_No
                WHERE od.Void = 1
            END;
    END TRY
    BEGIN CATCH
    ; THROW
    END CATCH

    BEGIN TRY
        BEGIN TRANSACTION

        --Gather all orders associated with approved RMA and fill
        ; WITH CteFill AS (
            SELECT odlink.order_no
            FROM #ProcessOrders AS rma
            JOIN dbo.Order_No AS odlink
                ON odlink.AuthNumber = CONVERT(VARCHAR(50), rma.Return_Order_No)
            WHERE
                odlink.Filled <> 1 OR odlink.Void <> 0
                AND rma.TBV_DECISION = 1
            UNION
            SELECT rma.Return_Order_No
            FROM #ProcessOrders AS rma
            WHERE rma.TBV_DECISION = 1
        )
        UPDATE od
        SET
            od.Process = 1
            , od.Filled = 1
            , od.Void = 0
            , od.DateFilled = GETDATE()
            , od.DateDue = dbo.fnCalculateDueDate(od.Account_ID, GETDATE())
            , od.Admin_Updated = GETDATE()
            , od.Admin_Name = 'FWA_RMA'
        FROM CteFill AS c
        JOIN dbo.order_no AS od
            ON
                od.Order_No = c.Order_No
                AND NOT EXISTS (SELECT 1 FROM #OrderIssues AS oi WHERE c.Order_No = oi.RMA_Order_No)

        --Gather all orders associated with denied RMA and void
        ; WITH cteVoid AS (
            SELECT odlink.order_no
            FROM #ProcessOrders AS rma
            JOIN dbo.Order_No AS odlink
                ON odlink.AuthNumber = CONVERT(VARCHAR(50), rma.Return_Order_No)
            WHERE
                rma.TBV_DECISION = 0
                AND odlink.Filled <> 1 OR odlink.Void <> 0
            UNION
            SELECT rma.Return_Order_No
            FROM #ProcessOrders AS rma
            WHERE rma.TBV_DECISION = 0
        )
        UPDATE od
        SET
            od.Process = 0
            , od.Filled = 0
            , od.Void = 1
            , od.DateFilled = GETDATE()
            --, od.DateDue = dbo.fnCalculateDueDate(od.Account_ID, GETDATE())
            , od.Admin_Updated = GETDATE()
            , od.Admin_Name = 'FWA_RMA'
        FROM CteVoid AS c
        JOIN dbo.order_no AS od
            ON
                od.Order_No = c.Order_No
                AND NOT EXISTS (SELECT 1 FROM #OrderIssues AS oi WHERE c.Order_No = oi.RMA_Order_No)

        UPDATE pub
        SET pub.RowProcessed = 1
        FROM #ProcessOrders AS rma
        JOIN Tracfone.tblFWA_RMA_Decision AS pub
            ON pub.RowID = rma.RowID
        WHERE NOT EXISTS (SELECT 1 FROM #OrderIssues AS oi WHERE rma.Return_Order_No = oi.RMA_Order_No)

        UPDATE pub
        SET pub.RowProcessed = 2
        FROM #ProcessOrders AS rma
        JOIN Tracfone.tblFWA_RMA_Decision AS pub
            ON pub.RowID = rma.RowID
        WHERE EXISTS (SELECT 1 FROM #OrderIssues AS oi WHERE rma.Return_Order_No = oi.RMA_Order_No)
        COMMIT TRANSACTION

    END TRY
    BEGIN CATCH
        ROLLBACK
        ; THROW
    END CATCH
END;
